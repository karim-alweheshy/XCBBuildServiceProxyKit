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
  public let timing: BazelExecutionTiming?

  public init(
    commandLineDisplayString: String? = nil,
    configuration: String,
    identity: String,
    label: String,
    mnemonic: String?,
    primaryOutput: String,
    succeeded: Bool?,
    timing: BazelExecutionTiming? = nil
  ) {
    self.commandLineDisplayString = commandLineDisplayString
    self.configuration = configuration
    self.identity = identity
    self.label = label
    self.mnemonic = mnemonic
    self.primaryOutput = primaryOutput
    self.succeeded = succeeded
    self.timing = timing
  }
}

public enum BEPEvent: Equatable, Sendable {
  case actionCompleted(BEPActionCompleted)
  case buildMetadata(BazelBuildMetadata)
  case progress(ProxyProgress)
  case reportedExecutedActionCount(Int)
  case targetCompleted(label: String, succeeded: Bool)
  case finished(succeeded: Bool)
}

public enum BazelBuildMetadata: Equatable, Hashable, Sendable {
  case invocation(buildToolVersion: String, id: String)
  case remoteCache(String)
  case resultsURL(String)
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
    maximumFileBytes: Int = 512 * 1024 * 1024,
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
  private var invocationID: String?
  private var emittedBuildMetadata = Set<BazelBuildMetadata>()
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
    events.append(contentsOf: parseBuildMetadata(in: object))
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
      let timing = try Self.parseActionTiming(payload)
      events.append(
        .actionCompleted(
          BEPActionCompleted(
            commandLineDisplayString: commandLineDisplayString,
            configuration: configuration,
            identity: identity,
            label: label,
            mnemonic: mnemonic,
            primaryOutput: primaryOutput,
            succeeded: succeeded,
            timing: timing
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

  private mutating func parseBuildMetadata(in object: [String: Any]) -> [BEPEvent] {
    var events = [BEPEvent]()

    if let started = object["started"] as? [String: Any],
      let rawInvocationID = started["uuid"] as? String,
      let uuid = UUID(uuidString: rawInvocationID)
    {
      let invocationID = uuid.uuidString.lowercased()
      if self.invocationID == nil {
        self.invocationID = invocationID
      }
      if self.invocationID == invocationID,
        let version = Self.safeDisplayValue(started["buildToolVersion"], maximumBytes: 128)
      {
        appendBuildMetadata(
          .invocation(buildToolVersion: version, id: invocationID),
          to: &events
        )
      }
    }

    if let identifier = object["id"] as? [String: Any],
      let commandLineID = identifier["structuredCommandLine"] as? [String: Any],
      commandLineID["commandLineLabel"] as? String == "canonical",
      let commandLine = object["structuredCommandLine"] as? [String: Any],
      let invocationID,
      let resultsURL = Self.resultsURL(
        in: commandLine,
        invocationID: invocationID
      )
    {
      appendBuildMetadata(.resultsURL(resultsURL), to: &events)
    }

    if let payload = object["buildMetadata"] as? [String: Any],
      let metadata = payload["metadata"] as? [String: Any],
      let remoteCache = Self.safeDisplayValue(metadata["REMOTE_CACHE"], maximumBytes: 128)
    {
      appendBuildMetadata(.remoteCache(remoteCache), to: &events)
    }

    return events
  }

  private mutating func appendBuildMetadata(
    _ metadata: BazelBuildMetadata,
    to events: inout [BEPEvent]
  ) {
    guard emittedBuildMetadata.insert(metadata).inserted else { return }
    events.append(.buildMetadata(metadata))
  }

  private static func safeDisplayValue(_ value: Any?, maximumBytes: Int) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.utf8.count <= maximumBytes,
      trimmed.unicodeScalars.allSatisfy({ scalar in
        (0x20...0x7E).contains(scalar.value)
      })
    else { return nil }
    return trimmed
  }

  private static func resultsURL(
    in commandLine: [String: Any],
    invocationID: String
  ) -> String? {
    guard let sections = commandLine["sections"] as? [[String: Any]] else { return nil }
    let candidates = sections.compactMap { section -> [[String: Any]]? in
      guard section["sectionLabel"] as? String == "command options",
        let optionList = section["optionList"] as? [String: Any]
      else { return nil }
      return optionList["option"] as? [[String: Any]]
    }
    .flatMap { $0 }
    .compactMap { option -> String? in
      guard option["optionName"] as? String == "bes_results_url" else { return nil }
      return option["optionValue"] as? String
    }
    let distinctCandidates = Set(candidates)
    guard distinctCandidates.count == 1, let base = distinctCandidates.first else { return nil }
    return safeResultsURL(base: base, invocationID: invocationID)
  }

  private static func safeResultsURL(base: String, invocationID: String) -> String? {
    guard !base.isEmpty,
      base.utf8.count <= 2_048 - invocationID.utf8.count,
      base.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
    else { return nil }
    let candidate = base + invocationID
    guard var components = URLComponents(string: candidate),
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return nil }

    switch components.scheme?.lowercased() {
    case "https":
      break
    case "http":
      let host = components.host?.lowercased()
      guard host == "localhost" || host == "127.0.0.1" || host == "::1" else { return nil }
    default:
      return nil
    }
    components.scheme = components.scheme?.lowercased()
    guard components.string == candidate else { return nil }
    return candidate
  }

  private static func parseActionTiming(
    _ payload: [String: Any]?
  ) throws -> BazelExecutionTiming? {
    let start = payload?["startTime"] as? String
    let end = payload?["endTime"] as? String
    guard start != nil || end != nil else { return nil }
    guard let start,
      let end,
      let startMicroseconds = parseRFC3339Microseconds(start),
      let endMicroseconds = parseRFC3339Microseconds(end),
      endMicroseconds >= startMicroseconds
    else { throw BEPStreamError.malformedJSONLine }
    return BazelExecutionTiming(
      startTimeUnixMicroseconds: startMicroseconds,
      durationMicroseconds: endMicroseconds - startMicroseconds
    )
  }

  /// Parses protobuf JSON's canonical UTC Timestamp spelling without floating-point rounding.
  private static func parseRFC3339Microseconds(_ value: String) -> UInt64? {
    let bytes = Array(value.utf8)
    guard bytes.count >= 20,
      bytes[4] == 0x2D,
      bytes[7] == 0x2D,
      bytes[10] == 0x54,
      bytes[13] == 0x3A,
      bytes[16] == 0x3A,
      bytes.last == 0x5A
    else { return nil }

    func decimal(_ range: Range<Int>) -> Int? {
      var result = 0
      for index in range {
        guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return nil }
        result = result * 10 + Int(bytes[index] - 0x30)
      }
      return result
    }

    guard let year = decimal(0..<4),
      let month = decimal(5..<7),
      let day = decimal(8..<10),
      let hour = decimal(11..<13),
      let minute = decimal(14..<16),
      let second = decimal(17..<19),
      (1...9999).contains(year),
      (1...12).contains(month),
      (0...23).contains(hour),
      (0...59).contains(minute),
      (0...59).contains(second)
    else { return nil }

    let leapYear =
      year.isMultiple(of: 4)
      && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

    let fractionalMicroseconds: Int
    if bytes[19] == 0x5A {
      guard bytes.count == 20 else { return nil }
      fractionalMicroseconds = 0
    } else {
      guard bytes[19] == 0x2E, (21...30).contains(bytes.count) else { return nil }
      let fractionalDigits = bytes[20..<(bytes.count - 1)]
      guard !fractionalDigits.isEmpty,
        fractionalDigits.count <= 9,
        fractionalDigits.allSatisfy({ (0x30...0x39).contains($0) })
      else { return nil }
      var microseconds = 0
      for index in 0..<6 {
        microseconds *= 10
        if index < fractionalDigits.count {
          microseconds += Int(
            fractionalDigits[
              fractionalDigits.index(
                fractionalDigits.startIndex,
                offsetBy: index
              )] - 0x30)
        }
      }
      fractionalMicroseconds = microseconds
    }

    var adjustedYear = year
    adjustedYear -= month <= 2 ? 1 : 0
    let era = adjustedYear / 400
    let yearOfEra = adjustedYear - era * 400
    let adjustedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let daysSinceUnixEpoch = era * 146_097 + dayOfEra - 719_468
    guard daysSinceUnixEpoch >= 0 else { return nil }
    let secondsSinceUnixEpoch =
      UInt64(daysSinceUnixEpoch) * 86_400
      + UInt64(hour * 3_600 + minute * 60 + second)
    return secondsSinceUnixEpoch * 1_000_000 + UInt64(fractionalMicroseconds)
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
