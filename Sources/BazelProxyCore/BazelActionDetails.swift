import Darwin
import Foundation

public struct BazelCommandDisplayLimits: Equatable, Sendable {
  public let maximumArgumentBytes: Int
  public let maximumArgumentCount: Int
  public let maximumDisplayBytes: Int

  public init(
    maximumArgumentBytes: Int = 16 * 1024,
    maximumArgumentCount: Int = 4_096,
    maximumDisplayBytes: Int = 64 * 1024
  ) {
    self.maximumArgumentBytes = maximumArgumentBytes
    self.maximumArgumentCount = maximumArgumentCount
    self.maximumDisplayBytes = maximumDisplayBytes
  }
}

enum BazelCommandDisplay {
  static let omittedPlaceholder = "<command omitted: exceeds display limits>"

  static func sanitize(
    _ arguments: [String],
    limits: BazelCommandDisplayLimits = BazelCommandDisplayLimits()
  ) -> String? {
    guard limits.maximumArgumentBytes > 0,
      limits.maximumArgumentCount > 0,
      limits.maximumDisplayBytes > 0
    else { return omittedPlaceholder }
    guard !arguments.isEmpty else { return nil }
    guard arguments.count <= limits.maximumArgumentCount else { return omittedPlaceholder }

    var rendered = [String]()
    rendered.reserveCapacity(arguments.count)
    var redactNext = false
    var renderedBytes = 0
    for argument in arguments {
      guard argument.utf8.count <= limits.maximumArgumentBytes else { return omittedPlaceholder }
      let sanitized: String
      if redactNext {
        sanitized = "<redacted>"
        redactNext = false
      } else if let assignment = credentialAssignment(argument) {
        sanitized = assignment
      } else if let attached = credentialColonValue(argument) {
        sanitized = attached
      } else if isCredentialOption(argument) {
        sanitized = argument
        redactNext = true
      } else if BuildProxySecurity.hasControlCharacters(argument) {
        sanitized = "<redacted>"
      } else {
        sanitized = redactURIUserInfo(argument)
      }
      let quoted = shellQuote(sanitized)
      let additionalBytes = quoted.utf8.count + (rendered.isEmpty ? 0 : 1)
      guard additionalBytes <= limits.maximumDisplayBytes - renderedBytes else {
        return omittedPlaceholder
      }
      rendered.append(quoted)
      renderedBytes += additionalBytes
    }
    return rendered.joined(separator: " ")
  }

  private static let credentialWords = [
    "api-key", "apikey", "auth", "authorization", "client-secret", "cookie", "header",
    "credential", "password", "passwd", "private-key", "secret", "token",
  ]

  private static func isCredentialOption(_ argument: String) -> Bool {
    guard argument.hasPrefix("-") else { return false }
    let name = argument.lowercased().replacingOccurrences(of: "_", with: "-")
    return credentialWords.contains { name.contains($0) }
  }

  private static func credentialAssignment(_ argument: String) -> String? {
    guard let equals = argument.firstIndex(of: "=") else {
      let lower = argument.lowercased()
      if lower.hasPrefix("authorization:") || lower.hasPrefix("cookie:") {
        return String(argument[..<argument.firstIndex(of: ":")!]) + ": <redacted>"
      }
      return nil
    }
    let name = String(argument[..<equals])
    let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
    guard credentialWords.contains(where: { normalized.contains($0) }) else { return nil }
    return name + "=<redacted>"
  }

  private static func credentialColonValue(_ argument: String) -> String? {
    guard argument.hasPrefix("-"), let colon = argument.firstIndex(of: ":") else { return nil }
    let name = String(argument[..<colon])
    let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
    guard credentialWords.contains(where: { normalized.contains($0) }) else { return nil }
    return name + ":<redacted>"
  }

  private static func redactURIUserInfo(_ argument: String) -> String {
    let queryRedacted = redactSensitiveQueryItems(argument)
    guard let scheme = queryRedacted.range(of: "://") else { return queryRedacted }
    let authorityStart = scheme.upperBound
    let suffix = queryRedacted[authorityStart...]
    let authorityEnd =
      suffix.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
      ?? queryRedacted.endIndex
    let authority = queryRedacted[authorityStart..<authorityEnd]
    guard let at = authority.lastIndex(of: "@") else { return queryRedacted }
    return String(queryRedacted[..<authorityStart]) + "<redacted>@"
      + String(queryRedacted[authority.index(after: at)...])
  }

  private static func redactSensitiveQueryItems(_ argument: String) -> String {
    guard let question = argument.firstIndex(of: "?") else { return argument }
    let fragment = argument[question...].firstIndex(of: "#") ?? argument.endIndex
    let queryStart = argument.index(after: question)
    let items = argument[queryStart..<fragment].split(
      separator: "&", omittingEmptySubsequences: false)
    var changed = false
    let redacted = items.map { item -> String in
      guard let equals = item.firstIndex(of: "=") else { return String(item) }
      let name = String(item[..<equals])
      let normalized =
        name.removingPercentEncoding?.lowercased()
        .replacingOccurrences(of: "_", with: "-") ?? name.lowercased()
      guard credentialWords.contains(where: { normalized.contains($0) }) else {
        return String(item)
      }
      changed = true
      return name + "=<redacted>"
    }
    guard changed else { return argument }
    return String(argument[..<queryStart]) + redacted.joined(separator: "&")
      + String(argument[fragment...])
  }

  private static func shellQuote(_ argument: String) -> String {
    guard !argument.isEmpty else { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@%+=:,./-"))
    if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public enum BazelCacheKind: Equatable, Sendable {
  case disk
  case remote
  case other
}

public struct BazelExecutionTiming: Equatable, Sendable {
  /// Wall-clock start time in microseconds since the Unix epoch, as reported by Bazel.
  public let startTimeUnixMicroseconds: UInt64

  /// Total wall-clock time Bazel spent running the spawn, in microseconds.
  public let durationMicroseconds: UInt64

  public init(startTimeUnixMicroseconds: UInt64, durationMicroseconds: UInt64) {
    self.startTimeUnixMicroseconds = startTimeUnixMicroseconds
    self.durationMicroseconds = durationMicroseconds
  }
}

public struct BazelExecutionRecord: Equatable, Sendable {
  public let cacheHit: Bool
  public let commandLineDisplayString: String?
  public let exitCode: Int?
  public let listedOutputs: [String]
  public let mnemonic: String?
  public let runner: String?
  public let status: String?
  public let targetLabel: String
  public let timing: BazelExecutionTiming?

  public init(
    cacheHit: Bool,
    commandLineDisplayString: String?,
    exitCode: Int?,
    listedOutputs: [String],
    mnemonic: String?,
    runner: String?,
    status: String?,
    targetLabel: String,
    timing: BazelExecutionTiming? = nil
  ) {
    self.cacheHit = cacheHit
    self.commandLineDisplayString = commandLineDisplayString
    self.exitCode = exitCode
    self.listedOutputs = listedOutputs
    self.mnemonic = mnemonic
    self.runner = runner
    self.status = status
    self.targetLabel = targetLabel
    self.timing = timing
  }

  var cacheKind: BazelCacheKind {
    switch runner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "remote cache hit": return .remote
    case "disk cache hit": return .disk
    default: return .other
    }
  }
}

public struct BazelExecutionLogValidation: Equatable, Sendable {
  public let fileBytes: Int
  public let records: [BazelExecutionRecord]
  private let recordsByKey: [BazelActionReconciliationKey: BazelExecutionRecord]

  init(
    fileBytes: Int,
    records: [BazelExecutionRecord],
    recordsByKey: [BazelActionReconciliationKey: BazelExecutionRecord]
  ) {
    self.fileBytes = fileBytes
    self.records = records
    self.recordsByKey = recordsByKey
  }

  func record(for key: BazelActionReconciliationKey) -> BazelExecutionRecord? {
    recordsByKey[key]
  }
}

public struct BazelExecutionLogLimits: Equatable, Sendable {
  public let command: BazelCommandDisplayLimits
  public let maximumDecodedBytes: Int
  public let maximumFileBytes: Int
  public let maximumLineBytes: Int
  public let maximumRecordCount: Int

  public init(
    maximumFileBytes: Int = 256 * 1024 * 1024,
    maximumLineBytes: Int = 64 * 1024 * 1024,
    maximumDecodedBytes: Int = 512 * 1024 * 1024,
    maximumRecordCount: Int = 1_000_000,
    command: BazelCommandDisplayLimits = BazelCommandDisplayLimits()
  ) {
    self.maximumDecodedBytes = maximumDecodedBytes
    self.maximumFileBytes = maximumFileBytes
    self.maximumLineBytes = maximumLineBytes
    self.maximumRecordCount = maximumRecordCount
    self.command = command
  }
}

public enum BazelExecutionLogError: LocalizedError, Equatable, Sendable {
  case ambiguousRecord(label: String, output: String)
  case compactDecodedLimitExceeded(Int)
  case compactRecordLimitExceeded(Int)
  case conflictingCompactEntryID(UInt32)
  case fileLimitExceeded(Int)
  case invalidLimits
  case lineLimitExceeded(Int)
  case malformedCompactLog
  case malformedJSONLine
  case missingCompactOutputReference(UInt32)
  case readFailed(errno: Int32)
  case unsafeFile(String)
  case wrongCompactOutputReference(UInt32)

  public var errorDescription: String? {
    switch self {
    case .ambiguousRecord(let label, let output):
      return "The Bazel execution log ambiguously repeats \(label) output \(output)."
    case .compactDecodedLimitExceeded(let limit):
      return "The Bazel compact execution log exceeds the \(limit)-byte decoded limit."
    case .compactRecordLimitExceeded(let limit):
      return "The Bazel compact execution log exceeds the \(limit)-record limit."
    case .conflictingCompactEntryID(let identifier):
      return "The Bazel compact execution log conflicts on entry ID \(identifier)."
    case .fileLimitExceeded(let limit):
      return "The Bazel execution log exceeds the \(limit)-byte file limit."
    case .invalidLimits:
      return "The Bazel execution-log limits are invalid."
    case .lineLimitExceeded(let limit):
      return "The Bazel execution log contains a record larger than \(limit) bytes."
    case .malformedCompactLog:
      return "The Bazel compact execution log is malformed or truncated."
    case .malformedJSONLine:
      return "The Bazel execution log contains malformed JSON."
    case .missingCompactOutputReference(let identifier):
      return "The Bazel compact execution log references missing output ID \(identifier)."
    case .readFailed(let errorNumber):
      return "The Bazel execution log read failed with errno \(errorNumber)."
    case .unsafeFile(let path):
      return "The Bazel execution log is missing, linked, non-regular, or oversized: \(path)"
    case .wrongCompactOutputReference(let identifier):
      return "The Bazel compact execution log output ID \(identifier) has the wrong entry type."
    }
  }
}

public enum BazelExecutionLogValidator {
  public static func validate(
    fileAt url: URL,
    limits: BazelExecutionLogLimits = BazelExecutionLogLimits()
  ) throws -> BazelExecutionLogValidation {
    guard limits.maximumLineBytes > 0,
      limits.maximumFileBytes >= limits.maximumLineBytes,
      limits.maximumDecodedBytes > 0,
      limits.maximumRecordCount > 0,
      limits.command.maximumArgumentBytes > 0,
      limits.command.maximumArgumentCount > 0,
      limits.command.maximumDisplayBytes > 0
    else { throw BazelExecutionLogError.invalidLimits }
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw BazelExecutionLogError.unsafeFile(url.absoluteString)
    }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw BazelExecutionLogError.unsafeFile(url.path) }
    defer { Darwin.close(descriptor) }

    var fileStatus = stat()
    guard Darwin.fstat(descriptor, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_size >= 0
    else { throw BazelExecutionLogError.unsafeFile(url.path) }
    guard fileStatus.st_size <= limits.maximumFileBytes else {
      throw BazelExecutionLogError.fileLimitExceeded(limits.maximumFileBytes)
    }

    var data = Data()
    data.reserveCapacity(Int(fileStatus.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limits.maximumFileBytes))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw BazelExecutionLogError.readFailed(errno: errno)
      }
      guard data.count <= limits.maximumFileBytes - count else {
        throw BazelExecutionLogError.fileLimitExceeded(limits.maximumFileBytes)
      }
      data.append(contentsOf: buffer.prefix(count))
    }

    let records: [BazelExecutionRecord]
    let malformedRecordError: BazelExecutionLogError
    if data.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
      records = try BazelCompactExecutionLogDecoder.decode(data, limits: limits)
      malformedRecordError = .malformedCompactLog
    } else {
      records = try decodeJSON(data, limits: limits)
      malformedRecordError = .malformedJSONLine
    }

    var recordsByKey = [BazelActionReconciliationKey: BazelExecutionRecord]()
    for record in records {
      try validate(record, limits: limits, malformedRecordError: malformedRecordError)
      for output in record.listedOutputs {
        let key = BazelActionReconciliationKey(label: record.targetLabel, primaryOutput: output)
        if let existing = recordsByKey[key] {
          guard reconciliationEquivalent(existing, record) else {
            throw BazelExecutionLogError.ambiguousRecord(label: key.label, output: output)
          }
        } else {
          recordsByKey[key] = record
        }
      }
    }
    return BazelExecutionLogValidation(
      fileBytes: data.count,
      records: records,
      recordsByKey: recordsByKey
    )
  }

  private static func decodeJSON(
    _ data: Data,
    limits: BazelExecutionLogLimits
  ) throws -> [BazelExecutionRecord] {
    var records = [BazelExecutionRecord]()
    for recordRange in try splitJSONSequence(
      data,
      maximumRecordBytes: limits.maximumLineBytes
    ) {
      let raw: RawExecutionRecord
      do {
        raw = try JSONDecoder().decode(
          RawExecutionRecord.self,
          from: data.subdata(in: recordRange)
        )
      } catch {
        throw BazelExecutionLogError.malformedJSONLine
      }
      let command = BazelCommandDisplay.sanitize(raw.commandArgs, limits: limits.command)
      let record = BazelExecutionRecord(
        cacheHit: raw.cacheHit,
        commandLineDisplayString: command,
        exitCode: raw.exitCode,
        listedOutputs: raw.listedOutputs,
        mnemonic: raw.mnemonic?.nilIfEmpty,
        runner: raw.runner?.nilIfEmpty,
        status: raw.status?.nilIfEmpty,
        targetLabel: raw.targetLabel,
        timing: nil
      )
      records.append(record)
    }
    return records
  }

  private static func validate(
    _ record: BazelExecutionRecord,
    limits: BazelExecutionLogLimits,
    malformedRecordError: BazelExecutionLogError
  ) throws {
    let boundedFields =
      [record.targetLabel] + record.listedOutputs
      + [record.mnemonic, record.runner, record.status].compactMap { $0 }
    guard record.listedOutputs.count <= limits.command.maximumArgumentCount,
      boundedFields.allSatisfy({
        $0.utf8.count <= limits.command.maximumArgumentBytes
          && !BuildProxySecurity.hasControlCharacters($0)
      })
    else { throw malformedRecordError }
    if record.cacheHit {
      guard record.exitCode.map({ $0 == 0 }) ?? true,
        record.status == nil
      else { throw malformedRecordError }
    }
  }

  /// Bazel 9 writes `--execution_log_json_file` as consecutive, pretty-printed top-level JSON
  /// objects separated only by whitespace. It is neither a JSON array nor JSON Lines. Split the
  /// bounded file structurally without decoding or retaining any non-allowlisted fields.
  private static func splitJSONSequence(
    _ data: Data,
    maximumRecordBytes: Int
  ) throws -> [Range<Data.Index>] {
    var index = data.startIndex
    var result = [Range<Data.Index>]()

    func isWhitespace(_ byte: UInt8) -> Bool {
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    while index < data.endIndex {
      while index < data.endIndex, isWhitespace(data[index]) { index += 1 }
      guard index < data.endIndex else { break }
      guard data[index] == 0x7B else { throw BazelExecutionLogError.malformedJSONLine }

      let start = index
      var expectedClosures = [UInt8]()
      var inString = false
      var escaped = false
      var recordEnd: Int?
      while index < data.endIndex {
        guard index - start < maximumRecordBytes else {
          throw BazelExecutionLogError.lineLimitExceeded(maximumRecordBytes)
        }
        let byte = data[index]
        if inString {
          if escaped {
            escaped = false
          } else if byte == 0x5C {
            escaped = true
          } else if byte == 0x22 {
            inString = false
          } else if byte < 0x20 {
            throw BazelExecutionLogError.malformedJSONLine
          }
        } else {
          switch byte {
          case 0x22:
            inString = true
          case 0x7B:
            expectedClosures.append(0x7D)
          case 0x5B:
            expectedClosures.append(0x5D)
          case 0x7D, 0x5D:
            guard expectedClosures.popLast() == byte else {
              throw BazelExecutionLogError.malformedJSONLine
            }
            if expectedClosures.isEmpty {
              recordEnd = index + 1
              index += 1
              break
            }
          default:
            break
          }
        }
        if recordEnd != nil { break }
        index += 1
      }
      guard let recordEnd, !inString, expectedClosures.isEmpty else {
        throw BazelExecutionLogError.malformedJSONLine
      }
      result.append(start..<recordEnd)
    }
    return result
  }

  private static func reconciliationEquivalent(
    _ lhs: BazelExecutionRecord,
    _ rhs: BazelExecutionRecord
  ) -> Bool {
    lhs.cacheHit == rhs.cacheHit
      && lhs.commandLineDisplayString == rhs.commandLineDisplayString
      && lhs.exitCode == rhs.exitCode
      && Set(lhs.listedOutputs) == Set(rhs.listedOutputs)
      && lhs.mnemonic == rhs.mnemonic
      && lhs.runner == rhs.runner
      && lhs.status == rhs.status
      && lhs.timing == rhs.timing
      && BazelActionReconciliationKey(label: lhs.targetLabel, primaryOutput: "").label
        == BazelActionReconciliationKey(label: rhs.targetLabel, primaryOutput: "").label
  }
}

private struct RawExecutionRecord: Decodable {
  let cacheHit: Bool
  let commandArgs: [String]
  let exitCode: Int?
  let listedOutputs: [String]
  let mnemonic: String?
  let runner: String?
  let status: String?
  let targetLabel: String

  private enum CodingKeys: String, CodingKey {
    case cacheHit
    case commandArgs
    case exitCode
    case listedOutputs
    case mnemonic
    case runner
    case status
    case targetLabel
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    cacheHit = try values.decodeIfPresent(Bool.self, forKey: .cacheHit) ?? false
    commandArgs = try values.decodeIfPresent([String].self, forKey: .commandArgs) ?? []
    exitCode = try values.decodeIfPresent(Int.self, forKey: .exitCode)
    listedOutputs = try values.decodeIfPresent([String].self, forKey: .listedOutputs) ?? []
    mnemonic = try values.decodeIfPresent(String.self, forKey: .mnemonic)
    runner = try values.decodeIfPresent(String.self, forKey: .runner)
    status = try values.decodeIfPresent(String.self, forKey: .status)
    targetLabel = try values.decodeIfPresent(String.self, forKey: .targetLabel) ?? ""
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
