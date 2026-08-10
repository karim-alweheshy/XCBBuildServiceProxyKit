import Darwin
import Foundation

public struct BEPActionCompleted: Equatable, Sendable {
  public let commandLineDisplayString: String?
  public let configuration: String
  public let identity: String
  public let label: String
  public let mnemonic: String?
  public let primaryOutput: String
  public let succeeded: Bool?

  public init(
    commandLineDisplayString: String? = nil,
    configuration: String,
    identity: String,
    label: String,
    mnemonic: String?,
    primaryOutput: String,
    succeeded: Bool?
  ) {
    self.commandLineDisplayString = commandLineDisplayString
    self.configuration = configuration
    self.identity = identity
    self.label = label
    self.mnemonic = mnemonic
    self.primaryOutput = primaryOutput
    self.succeeded = succeeded
  }
}

public enum BEPEvent: Equatable, Sendable {
  case actionCompleted(BEPActionCompleted)
  case progress(ProxyProgress)
  case reportedExecutedActionCount(Int)
  case targetCompleted(label: String, succeeded: Bool)
  case finished(succeeded: Bool)
}

extension BEPEvent {
  public static func actionCompleted(identity: String, succeeded: Bool?) -> Self {
    let components = identity.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    return .actionCompleted(
      BEPActionCompleted(
        commandLineDisplayString: nil,
        configuration: components.count > 2 ? String(components[2]) : "",
        identity: identity,
        label: components.first.map(String.init) ?? "",
        mnemonic: nil,
        primaryOutput: components.count > 1 ? String(components[1]) : "",
        succeeded: succeeded
      )
    )
  }
}

public struct BEPResult: Equatable, Sendable {
  public let completedActionIDs: Set<String>
  public let failedActionIDs: Set<String>
  public let failedTargetLabels: Set<String>
  public let reportedExecutedActionCount: Int?
  public let succeeded: Bool

  public init(
    completedActionIDs: Set<String>,
    failedActionIDs: Set<String>,
    failedTargetLabels: Set<String>,
    reportedExecutedActionCount: Int?,
    succeeded: Bool
  ) {
    self.completedActionIDs = completedActionIDs
    self.failedActionIDs = failedActionIDs
    self.failedTargetLabels = failedTargetLabels
    self.reportedExecutedActionCount = reportedExecutedActionCount
    self.succeeded = succeeded
  }
}

public struct BEPValidation: Equatable, Sendable {
  public let events: [BEPEvent]
  public let result: BEPResult
}

public struct BEPFinalization: Equatable, Sendable {
  public let events: [BEPEvent]
  public let result: BEPResult
}

public struct BEPStreamLimits: Equatable, Sendable {
  public let maximumFileBytes: Int
  public let maximumLineBytes: Int

  public init(
    maximumFileBytes: Int = 256 * 1024 * 1024,
    maximumLineBytes: Int = 4 * 1024 * 1024
  ) {
    self.maximumFileBytes = maximumFileBytes
    self.maximumLineBytes = maximumLineBytes
  }
}

public enum BEPStreamError: LocalizedError, Equatable, Sendable {
  case actionIdentityIsMissing
  case consumedAfterFinish
  case contradictoryTerminalResult
  case duplicateActionIdentity(String)
  case duplicateFinishedEvent
  case fileLimitExceeded(Int)
  case invalidCount(String)
  case invalidLimits
  case lineLimitExceeded(Int)
  case malformedJSONLine
  case missingFinishedEvent
  case readFailed(errno: Int32)
  case unsafeFile(String)
  case validatorAlreadyFinished

  public var errorDescription: String? {
    switch self {
    case .actionIdentityIsMissing:
      return "A BEP action-completed event has no stable identity."
    case .consumedAfterFinish:
      return "BEP bytes were supplied after validation finished."
    case .contradictoryTerminalResult:
      return "BEP reports success together with a failed action or target."
    case .duplicateActionIdentity(let identity):
      return "BEP repeats the action-completed identity \(identity)."
    case .duplicateFinishedEvent:
      return "BEP contains more than one finished event."
    case .fileLimitExceeded(let limit):
      return "BEP exceeds the \(limit)-byte file limit."
    case .invalidCount(let field):
      return "BEP contains an invalid nonnegative count for \(field)."
    case .invalidLimits:
      return "BEP stream limits must be positive and the file limit must cover one line."
    case .lineLimitExceeded(let limit):
      return "BEP contains a line larger than the \(limit)-byte line limit."
    case .malformedJSONLine:
      return "BEP contains an empty, malformed, or non-object JSON line."
    case .missingFinishedEvent:
      return "BEP does not contain exactly one finished event."
    case .readFailed(let errorNumber):
      return "BEP descriptor read failed with errno \(errorNumber)."
    case .unsafeFile(let path):
      return "BEP is missing, linked, non-regular, or oversized: \(path)"
    case .validatorAlreadyFinished:
      return "BEP validation was finished more than once."
    }
  }
}

/// Incrementally parses only a safe allowlist from Bazel's JSONL build-event stream.
public struct BEPStreamValidator: Sendable {
  private let limits: BEPStreamLimits
  private var completedActionIDs = Set<String>()
  private var failedActionIDs = Set<String>()
  private var failedTargetLabels = Set<String>()
  private var finishedResult: Bool?
  private var isFinished = false
  private var pending = Data()
  private var reportedExecutedActionCount: Int?
  private var totalBytes = 0

  public init(limits: BEPStreamLimits = BEPStreamLimits()) throws {
    guard limits.maximumLineBytes > 0,
      limits.maximumFileBytes >= limits.maximumLineBytes
    else {
      throw BEPStreamError.invalidLimits
    }
    self.limits = limits
  }

  public mutating func consume(_ bytes: Data) throws -> [BEPEvent] {
    guard !isFinished else { throw BEPStreamError.consumedAfterFinish }
    guard bytes.count <= limits.maximumFileBytes - totalBytes else {
      throw BEPStreamError.fileLimitExceeded(limits.maximumFileBytes)
    }
    totalBytes += bytes.count

    var events = [BEPEvent]()
    var start = bytes.startIndex
    while let newline = bytes[start...].firstIndex(of: 0x0A) {
      try appendPending(bytes[start..<newline])
      events.append(contentsOf: try parsePendingLine())
      start = bytes.index(after: newline)
    }
    try appendPending(bytes[start...])
    return events
  }

  public mutating func finish() throws -> BEPResult {
    try finishWithEvents().result
  }

  public mutating func finishWithEvents() throws -> BEPFinalization {
    guard !isFinished else { throw BEPStreamError.validatorAlreadyFinished }
    isFinished = true
    var finalEvents = [BEPEvent]()
    if !pending.isEmpty {
      finalEvents = try parsePendingLine()
    }
    guard let succeeded = finishedResult else {
      throw BEPStreamError.missingFinishedEvent
    }
    guard !succeeded || (failedActionIDs.isEmpty && failedTargetLabels.isEmpty) else {
      throw BEPStreamError.contradictoryTerminalResult
    }
    return BEPFinalization(
      events: finalEvents,
      result: BEPResult(
        completedActionIDs: completedActionIDs,
        failedActionIDs: failedActionIDs,
        failedTargetLabels: failedTargetLabels,
        reportedExecutedActionCount: reportedExecutedActionCount,
        succeeded: succeeded
      )
    )
  }

  /// Reads a completed BEP through one no-follow descriptor while preserving incremental bounds.
  public static func validate(
    fileAt url: URL,
    limits: BEPStreamLimits = BEPStreamLimits()
  ) throws -> BEPValidation {
    var validator = try BEPStreamValidator(limits: limits)
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw BEPStreamError.unsafeFile(url.absoluteString)
    }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw BEPStreamError.unsafeFile(url.path) }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0,
      status.st_size <= limits.maximumFileBytes
    else {
      throw BEPStreamError.unsafeFile(url.path)
    }

    var events = [BEPEvent]()
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limits.maximumFileBytes))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw BEPStreamError.readFailed(errno: errno)
      }
      events.append(contentsOf: try validator.consume(Data(buffer.prefix(count))))
    }
    let finalization = try validator.finishWithEvents()
    events.append(contentsOf: finalization.events)
    return BEPValidation(events: events, result: finalization.result)
  }

  private mutating func appendPending(_ bytes: Data.SubSequence) throws {
    guard bytes.count <= limits.maximumLineBytes - pending.count else {
      throw BEPStreamError.lineLimitExceeded(limits.maximumLineBytes)
    }
    pending.append(contentsOf: bytes)
  }

  private mutating func parsePendingLine() throws -> [BEPEvent] {
    defer { pending.removeAll(keepingCapacity: true) }
    guard !pending.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any]
    else {
      throw BEPStreamError.malformedJSONLine
    }

    var events = [BEPEvent]()
    if let progress = object["progress"] as? [String: Any],
      let standardError = progress["stderr"] as? String,
      let progress = Self.parseProgress(in: standardError)
    {
      events.append(
        .progress(
          ProxyProgress(
            activity: progress.activity,
            completed: progress.completed,
            source: .interactiveHint,
            total: progress.total
          )
        )
      )
    }

    if let metrics = object["buildMetrics"] as? [String: Any],
      let summary = metrics["actionSummary"] as? [String: Any],
      summary.keys.contains("actionsExecuted")
    {
      guard let count = Self.nonnegativeInteger(summary["actionsExecuted"]) else {
        throw BEPStreamError.invalidCount("buildMetrics.actionSummary.actionsExecuted")
      }
      if let previous = reportedExecutedActionCount, previous != count {
        throw BEPStreamError.invalidCount("buildMetrics.actionSummary.actionsExecuted")
      }
      reportedExecutedActionCount = count
      events.append(.reportedExecutedActionCount(count))
    }

    if let identifier = object["id"] as? [String: Any],
      let action = identifier["actionCompleted"] as? [String: Any]
    {
      let label = action["label"] as? String ?? ""
      let primaryOutput = action["primaryOutput"] as? String ?? ""
      let configuration =
        action["configuration"] as? String
        ?? (action["configuration"] as? [String: Any])?["id"] as? String
        ?? ""
      let identity = [label, primaryOutput, configuration].joined(separator: "|")
      guard identity != "||" else { throw BEPStreamError.actionIdentityIsMissing }
      guard completedActionIDs.insert(identity).inserted else {
        throw BEPStreamError.duplicateActionIdentity(identity)
      }
      let payload = object["action"] as? [String: Any]
      let succeeded = payload?["success"] as? Bool
      if succeeded == false {
        failedActionIDs.insert(identity)
      }
      let mnemonic = (payload?["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let commandLineDisplayString: String?
      if let commandLine = payload?["commandLine"] as? [String] {
        commandLineDisplayString = BazelCommandDisplay.sanitize(commandLine)
      } else {
        commandLineDisplayString = nil
      }
      events.append(
        .actionCompleted(
          BEPActionCompleted(
            commandLineDisplayString: commandLineDisplayString,
            configuration: configuration,
            identity: identity,
            label: label,
            mnemonic: mnemonic,
            primaryOutput: primaryOutput,
            succeeded: succeeded
          )
        )
      )
    }

    if let identifier = object["id"] as? [String: Any],
      let target = identifier["targetCompleted"] as? [String: Any],
      let label = target["label"] as? String,
      let completed = object["completed"] as? [String: Any],
      let succeeded = completed["success"] as? Bool
    {
      if !succeeded {
        failedTargetLabels.insert(label)
      }
      events.append(.targetCompleted(label: label, succeeded: succeeded))
    }

    if let finished = object["finished"] as? [String: Any],
      let succeeded = finished["overallSuccess"] as? Bool
    {
      guard finishedResult == nil else { throw BEPStreamError.duplicateFinishedEvent }
      finishedResult = succeeded
      events.append(.finished(succeeded: succeeded))
    }
    return events
  }

  private static func parseProgress(
    in text: String
  ) -> (activity: String?, completed: Int, total: Int)? {
    var best: (activity: String?, completed: Int, total: Int)?
    for line in text.split(whereSeparator: \Character.isNewline) {
      let sanitizedLine = strippingTerminalEscapes(from: line)
      guard let open = sanitizedLine.firstIndex(of: "["),
        let close = sanitizedLine[open...].firstIndex(of: "]")
      else { continue }
      let fraction = sanitizedLine[sanitizedLine.index(after: open)..<close]
        .split(separator: "/", maxSplits: 1)
        .map(String.init)
      guard fraction.count == 2,
        let completed = parseProgressNumber(fraction[0]),
        let total = parseProgressNumber(fraction[1]),
        total > 0,
        completed >= 0,
        completed <= total
      else { continue }
      let suffix = sanitizedLine[sanitizedLine.index(after: close)...]
        .trimmingCharacters(in: .whitespaces)
      let activity = suffix.isEmpty ? nil : String(suffix.prefix(512))
      if best == nil || completed > best!.completed || total > best!.total {
        best = (activity, completed, total)
      }
    }
    return best
  }

  private static func parseProgressNumber(_ value: String) -> Int? {
    let normalized = value.filter { character in
      character != "," && !character.isWhitespace
    }
    guard !normalized.isEmpty, normalized.allSatisfy(\.isNumber) else { return nil }
    return Int(normalized)
  }

  /// Bazel's terminal reporter wraps progress in ANSI control sequences even when it is copied
  /// into a JSON BEP progress payload. Retain printable text only and consume CSI/OSC sequences so
  /// control bytes never reach Xcode's status message.
  private static func strippingTerminalEscapes(from line: Substring) -> String {
    enum State {
      case controlSequence
      case escape
      case operatingSystemCommand
      case plain
    }

    var state = State.plain
    var result = String.UnicodeScalarView()
    for scalar in line.unicodeScalars {
      switch state {
      case .plain:
        if scalar.value == 0x1B {
          state = .escape
        } else if scalar.value >= 0x20 && scalar.value != 0x7F {
          result.append(scalar)
        }
      case .escape:
        switch scalar.value {
        case 0x5B:
          state = .controlSequence
        case 0x5D:
          state = .operatingSystemCommand
        default:
          state = .plain
        }
      case .controlSequence:
        if (0x40...0x7E).contains(scalar.value) {
          state = .plain
        }
      case .operatingSystemCommand:
        if scalar.value == 0x07 {
          state = .plain
        }
      }
    }
    return String(result)
  }

  private static func nonnegativeInteger(_ value: Any?) -> Int? {
    if value is Bool { return nil }
    let integer: Int?
    if let value = value as? Int {
      integer = value
    } else if let value = value as? String {
      integer = Int(value)
    } else {
      integer = nil
    }
    guard let integer, integer >= 0 else { return nil }
    return integer
  }
}
