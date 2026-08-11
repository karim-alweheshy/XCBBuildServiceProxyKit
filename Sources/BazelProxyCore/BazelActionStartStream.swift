import Darwin
import Foundation

public struct BazelActionStarted: Equatable, Sendable {
  public let configuration: String
  public let description: String
  public let executionPlatform: String
  public let label: String
  public let mnemonic: String
  public let observedTimeUnixMicroseconds: UInt64
  public let sequence: Int

  public init(
    configuration: String,
    description: String,
    executionPlatform: String,
    label: String,
    mnemonic: String,
    observedTimeUnixMicroseconds: UInt64,
    sequence: Int
  ) {
    self.configuration = configuration
    self.description = description
    self.executionPlatform = executionPlatform
    self.label = label
    self.mnemonic = mnemonic
    self.observedTimeUnixMicroseconds = observedTimeUnixMicroseconds
    self.sequence = sequence
  }
}

public struct BazelActionStartValidation: Equatable, Sendable {
  public let fileBytes: Int
  public let starts: [BazelActionStarted]
}

public struct BazelActionStartStreamLimits: Equatable, Sendable {
  public let maximumFieldBytes: Int
  public let maximumFileBytes: Int
  public let maximumLineBytes: Int
  public let maximumRecordCount: Int

  public init(
    maximumFieldBytes: Int = 16 * 1024,
    maximumFileBytes: Int = 64 * 1024 * 1024,
    maximumLineBytes: Int = 64 * 1024,
    maximumRecordCount: Int = 1_000_000
  ) {
    self.maximumFieldBytes = maximumFieldBytes
    self.maximumFileBytes = maximumFileBytes
    self.maximumLineBytes = maximumLineBytes
    self.maximumRecordCount = maximumRecordCount
  }

  fileprivate var isValid: Bool {
    maximumFieldBytes > 0
      && maximumFileBytes > 0
      && maximumLineBytes > 0
      && maximumLineBytes <= maximumFileBytes
      && maximumRecordCount > 0
  }
}

public enum BazelActionStartStreamError: LocalizedError, Equatable, Sendable {
  case fileLimitExceeded(Int)
  case invalidField(String)
  case invalidLimits
  case invalidSchemaVersion
  case invalidSequence
  case lineLimitExceeded(Int)
  case malformedJSONLine
  case readFailed(errno: Int32)
  case recordLimitExceeded(Int)
  case unsafeFile(String)

  public var errorDescription: String? {
    switch self {
    case .fileLimitExceeded(let limit):
      return "The Bazel action-start stream exceeds the \(limit)-byte file limit."
    case .invalidField(let field):
      return "The Bazel action-start stream contains an invalid \(field)."
    case .invalidLimits:
      return "The Bazel action-start stream limits are invalid."
    case .invalidSchemaVersion:
      return "The Bazel action-start stream uses an unsupported schema version."
    case .invalidSequence:
      return "The Bazel action-start stream sequence is not contiguous."
    case .lineLimitExceeded(let limit):
      return "The Bazel action-start stream contains a line larger than \(limit) bytes."
    case .malformedJSONLine:
      return "The Bazel action-start stream contains malformed JSON."
    case .readFailed(let errorNumber):
      return "The Bazel action-start stream read failed with errno \(errorNumber)."
    case .recordLimitExceeded(let limit):
      return "The Bazel action-start stream exceeds the \(limit)-record limit."
    case .unsafeFile(let path):
      return "The Bazel action-start stream is linked, non-regular, or oversized: \(path)"
    }
  }
}

/// Follows the private, rules-owned action-start JSONL while its Bazel adapter is running.
///
/// Older generated projects do not create the stream, so absence remains a supported fallback.
/// Once present, the descriptor and published path are pinned and every byte is bounded and
/// validated before a start reaches the bridge.
public struct BazelActionStartStreamFollower: Sendable {
  public typealias CompletionProbe = @Sendable () async -> Bool
  public typealias EventHandler = @Sendable (BazelActionStarted) async throws -> Void

  private let limits: BazelActionStartStreamLimits
  private let pollInterval: Duration

  public init(
    limits: BazelActionStartStreamLimits = BazelActionStartStreamLimits(),
    pollInterval: Duration = .milliseconds(10)
  ) {
    self.limits = limits
    self.pollInterval = pollInterval
  }

  public func follow(
    fileAt url: URL,
    processIsComplete: @escaping CompletionProbe,
    onEvent: @escaping EventHandler
  ) async throws -> BazelActionStartValidation? {
    guard limits.isValid else { throw BazelActionStartStreamError.invalidLimits }
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw BazelActionStartStreamError.unsafeFile(url.absoluteString)
    }

    var descriptor: Int32?
    var identity: ActionStartFileIdentity?
    var decoder = BazelActionStartStreamDecoder(limits: limits)
    var starts = [BazelActionStarted]()
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limits.maximumFileBytes))
    defer {
      if let descriptor { Darwin.close(descriptor) }
    }

    while true {
      try Task.checkCancellation()
      let processComplete = await processIsComplete()

      if descriptor == nil {
        switch try openIfPresent(url) {
        case .missing where processComplete:
          return nil
        case .missing:
          try await Task.sleep(for: pollInterval)
          continue
        case .opened(let openedDescriptor, let openedIdentity):
          descriptor = openedDescriptor
          identity = openedIdentity
        }
      }

      guard let descriptor else { continue }
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
          if errno == EINTR { continue }
          throw BazelActionStartStreamError.readFailed(errno: errno)
        }
        let parsed = try decoder.consume(Data(buffer.prefix(count)))
        starts.append(contentsOf: parsed)
        for start in parsed {
          try await onEvent(start)
        }
      }

      if processComplete {
        guard let identity, pathStillNamesIdentity(url, identity: identity) else {
          throw BazelActionStartStreamError.unsafeFile(url.path)
        }
        try decoder.finish()
        return BazelActionStartValidation(fileBytes: decoder.consumedBytes, starts: starts)
      }

      try await Task.sleep(for: pollInterval)
    }
  }

  private func openIfPresent(_ url: URL) throws -> ActionStartOpenResult {
    let descriptor = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
      guard let fileSystemPath else { return -1 }
      return Darwin.open(fileSystemPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if descriptor < 0 {
      if errno == ENOENT { return .missing }
      throw BazelActionStartStreamError.unsafeFile(url.path)
    }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1,
      status.st_size >= 0,
      status.st_size <= limits.maximumFileBytes
    else {
      Darwin.close(descriptor)
      throw BazelActionStartStreamError.unsafeFile(url.path)
    }
    return .opened(
      descriptor,
      ActionStartFileIdentity(device: status.st_dev, inode: status.st_ino)
    )
  }

  private func pathStillNamesIdentity(
    _ url: URL,
    identity: ActionStartFileIdentity
  ) -> Bool {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
      guard let fileSystemPath else { return -1 }
      return Darwin.lstat(fileSystemPath, &status)
    }
    return result == 0
      && status.st_mode & S_IFMT == S_IFREG
      && status.st_nlink == 1
      && status.st_dev == identity.device
      && status.st_ino == identity.inode
  }
}

private struct BazelActionStartStreamDecoder {
  private(set) var consumedBytes = 0
  private var nextSequence = 1
  private var pending = Data()
  private let limits: BazelActionStartStreamLimits

  init(limits: BazelActionStartStreamLimits) {
    self.limits = limits
  }

  mutating func consume(_ data: Data) throws -> [BazelActionStarted] {
    guard data.count <= limits.maximumFileBytes - consumedBytes else {
      throw BazelActionStartStreamError.fileLimitExceeded(limits.maximumFileBytes)
    }
    consumedBytes += data.count
    pending.append(data)
    var result = [BazelActionStarted]()
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = pending[..<newline]
      guard !line.isEmpty else { throw BazelActionStartStreamError.malformedJSONLine }
      guard line.count <= limits.maximumLineBytes else {
        throw BazelActionStartStreamError.lineLimitExceeded(limits.maximumLineBytes)
      }
      guard nextSequence <= limits.maximumRecordCount else {
        throw BazelActionStartStreamError.recordLimitExceeded(limits.maximumRecordCount)
      }
      let start = try decode(Data(line))
      result.append(start)
      nextSequence += 1
      pending.removeSubrange(...newline)
    }
    guard pending.count <= limits.maximumLineBytes else {
      throw BazelActionStartStreamError.lineLimitExceeded(limits.maximumLineBytes)
    }
    return result
  }

  func finish() throws {
    guard pending.isEmpty else { throw BazelActionStartStreamError.malformedJSONLine }
  }

  private func decode(_ data: Data) throws -> BazelActionStarted {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw BazelActionStartStreamError.malformedJSONLine
    }
    guard let object = value as? [String: Any] else {
      throw BazelActionStartStreamError.malformedJSONLine
    }
    guard Self.integer(object["schemaVersion"]) == 1 else {
      throw BazelActionStartStreamError.invalidSchemaVersion
    }
    guard Self.integer(object["sequence"]) == nextSequence else {
      throw BazelActionStartStreamError.invalidSequence
    }
    guard let observed = Self.unsignedInteger(object["observedTimeUnixMicroseconds"]),
      observed > 0
    else {
      throw BazelActionStartStreamError.invalidField("observedTimeUnixMicroseconds")
    }
    let configuration = try field("configuration", in: object)
    let description = try field("description", in: object)
    let executionPlatform = try field("executionPlatform", in: object)
    let label = try field("label", in: object)
    let mnemonic = try field("mnemonic", in: object)
    return BazelActionStarted(
      configuration: configuration,
      description: description,
      executionPlatform: executionPlatform,
      label: label,
      mnemonic: mnemonic,
      observedTimeUnixMicroseconds: observed,
      sequence: nextSequence
    )
  }

  private func field(_ name: String, in object: [String: Any]) throws -> String {
    guard let value = object[name] as? String,
      !value.isEmpty,
      value.utf8.count <= limits.maximumFieldBytes,
      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { throw BazelActionStartStreamError.invalidField(name) }
    return value
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let integer = number.int64Value
    guard number.doubleValue == Double(integer),
      integer >= Int64(Int.min),
      integer <= Int64(Int.max)
    else { return nil }
    return Int(integer)
  }

  private static func unsignedInteger(_ value: Any?) -> UInt64? {
    guard let integer = integer(value), integer >= 0 else { return nil }
    return UInt64(integer)
  }
}

private enum ActionStartOpenResult {
  case missing
  case opened(Int32, ActionStartFileIdentity)
}

private struct ActionStartFileIdentity {
  let device: dev_t
  let inode: ino_t
}
