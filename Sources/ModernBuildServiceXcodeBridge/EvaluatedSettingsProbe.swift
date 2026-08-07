import Darwin
import Foundation
import ModernBuildServiceProxyCore
import SWBProtocol

public enum EvaluatedSettingsProbeConfigurationError: Error, Equatable {
  case manifestTooLarge
  case malformedManifest
  case unsupportedManifestSchema(Int)
  case tooManyEnvironmentKeys
  case duplicateEnvironmentKey(String)
  case invalidEnvironmentKey(String)
  case manifestNotRegularFile
}

private struct SettingsProbeManifest: Decodable {
  struct Invocation: Decodable {
    let environmentKeys: [String]
  }

  let schemaVersion: Int
  let invocation: Invocation
}

private enum QueryOutcome {
  case values([String])
  case failure(EvaluatedSettingsProbeFailureCode)
}

private struct ActiveQuery {
  let channel: UInt64
  var outcome: QueryOutcome?
  var responseConsumed = false
}

public final class EvaluatedSettingsProbe: BuildServiceFrameInterceptor {
  public static let fixedPlanRoleKeys = [
    "BAZEL_LABEL",
    "BAZEL_TARGET_ID",
    "BAZEL_INTEGRATION_DIR",
    "BAZEL_OUT",
    "BAZEL_WORKSPACE_ROOT",
    "SRCROOT",
    "TARGET_BUILD_DIR",
    "FULL_PRODUCT_NAME",
    "TARGET_NAME",
    "PROJECT_NAME",
    "PROJECT_FILE_PATH",
    "ENABLE_PREVIEWS",
  ]

  private static let targetScopedKeys: Set<String> = [
    "BAZEL_LABEL",
    "BAZEL_TARGET_ID",
    "FULL_PRODUCT_NAME",
    "TARGET_BUILD_DIR",
    "TARGET_NAME",
  ]
  private static let requiredPlanRoleKeys = Set(fixedPlanRoleKeys)
  private static let maximumManifestBytes = 1024 * 1024
  private static let maximumEnvironmentKeyCount = 256

  private let reportWriter: EvaluatedSettingsProbeReportWriter
  private let timeout: TimeInterval
  private let condition = NSCondition()
  private var evaluationKeys: [String] = []
  private var isEnabled = false
  private var hasAttemptedCreateBuild = false
  private var activeQuery: ActiveQuery?
  private var drainingResponseChannels: Set<UInt64> = []
  private var hasWrittenReport = false

  public init(
    manifestURL: URL,
    reportURL: URL,
    timeout: TimeInterval = 2
  ) throws {
    reportWriter = try EvaluatedSettingsProbeReportWriter(fileURL: reportURL)
    self.timeout = timeout

    do {
      let environmentKeys = try Self.loadEnvironmentKeys(from: manifestURL)
      evaluationKeys =
        Self.fixedPlanRoleKeys
        + environmentKeys.filter {
          !Self.fixedPlanRoleKeys.contains($0)
        }
      isEnabled = true
    } catch {
      try reportWriter.write(
        EvaluatedSettingsProbeReport(
          schemaVersion: 1,
          status: .failed,
          failureCodes: [.invalidManifest],
          targetCount: 0,
          targets: []
        )
      )
      hasWrittenReport = true
    }
  }

  public func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    switch direction {
    case .clientToService:
      return isEnabled && !hasAttemptedCreateBuild && messageName == CreateBuildRequest.name
    case .serviceToClient:
      return activeQuery?.channel == channel || drainingResponseChannels.contains(channel)
    }
  }

  public func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    send: (BuildServiceRawFrame) throws -> Void
  ) throws -> Bool {
    switch direction {
    case .clientToService:
      handleCreateBuild(frame: frame, send: send)
      return false
    case .serviceToClient:
      return handleServiceFrame(frame)
    }
  }

  public func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) -> Bool {
    switch direction {
    case .clientToService:
      condition.lock()
      hasAttemptedCreateBuild = true
      condition.unlock()
      writeReport(
        status: .failed,
        failures: [.capturedPayloadTooLarge],
        targetCount: 0,
        targets: []
      )
      return false
    case .serviceToClient:
      condition.lock()
      if activeQuery?.channel == channel {
        activeQuery?.outcome = .failure(.capturedPayloadTooLarge)
        activeQuery?.responseConsumed = true
        condition.broadcast()
      } else {
        drainingResponseChannels.remove(channel)
      }
      condition.unlock()
      return true
    }
  }

  public func finishIfNeeded() {
    condition.lock()
    let shouldWrite = !hasWrittenReport
    condition.unlock()
    if shouldWrite {
      writeReport(status: .notRun, failures: [], targetCount: 0, targets: [])
    }
  }

  private func handleCreateBuild(
    frame: BuildServiceRawFrame,
    send: (BuildServiceRawFrame) throws -> Void
  ) {
    condition.lock()
    guard isEnabled, !hasAttemptedCreateBuild else {
      condition.unlock()
      return
    }
    hasAttemptedCreateBuild = true
    condition.unlock()

    let request: CreateBuildRequest
    do {
      request = try SwiftBuildProtocolCodec.decodeCreateBuild(frame.payload)
    } catch {
      writeReport(
        status: .failed,
        failures: [.createBuildDecodeFailed],
        targetCount: 0,
        targets: []
      )
      return
    }

    let configuredTargets = request.request.configuredTargets
    guard !configuredTargets.isEmpty else {
      writeReport(
        status: .failed,
        failures: [.noConfiguredTargets],
        targetCount: 0,
        targets: []
      )
      return
    }

    var rawValuesByTarget: [[String]] = []
    var targetReports: [EvaluatedSettingsProbeTargetReport] = []
    var failures: [EvaluatedSettingsProbeFailureCode] = []

    for (targetIndex, configuredTarget) in configuredTargets.enumerated() {
      let parameters = configuredTarget.parameters ?? request.request.parameters
      let requestPayload = SwiftBuildProtocolCodec.encodeAllExportedMacrosAndValuesRequest(
        sessionHandle: request.sessionHandle,
        targetGUID: configuredTarget.guid,
        buildParameters: parameters
      )
      switch performQuery(
        payload: requestPayload,
        channel: frame.channel,
        send: send
      ) {
      case .values(let values):
        rawValuesByTarget.append(values)
        targetReports.append(
          EvaluatedSettingsProbeTargetReport(
            targetIndex: targetIndex,
            settings: zip(evaluationKeys, values).map {
              EvaluatedSettingsProbeValueMetadata(key: $0.0, value: $0.1)
            }
          )
        )
        if requiredPlanRoleIsMissing(in: values) {
          appendUnique(.missingRequiredPlanRole, to: &failures)
        }
      case .failure(let failure):
        appendUnique(failure, to: &failures)
      }
      if !failures.isEmpty { break }
    }

    if failures.isEmpty {
      if sharedValuesDisagree(rawValuesByTarget) {
        failures.append(.multiTargetSharedValueDisagreement)
      }
      if previewStateDisagrees(request: request, valuesByTarget: rawValuesByTarget) {
        failures.append(.previewStateDisagreement)
      }
    }

    writeReport(
      status: failures.isEmpty ? .succeeded : .failed,
      failures: failures,
      targetCount: configuredTargets.count,
      targets: targetReports
    )
  }

  private func handleServiceFrame(_ frame: BuildServiceRawFrame) -> Bool {
    if frame.messageName == AllExportedMacrosAndValuesResponse.name {
      let outcome: QueryOutcome
      do {
        outcome = .values(
          try SwiftBuildProtocolCodec.decodeAllExportedMacrosAndValuesResponse(
            frame.payload,
            selecting: evaluationKeys
          )
        )
      } catch {
        outcome = .failure(.responseDecodeFailed)
      }
      completeServiceResponse(on: frame.channel, outcome: outcome)
      return true
    }

    if frame.messageName == ErrorResponse.name {
      completeServiceResponse(
        on: frame.channel,
        outcome: .failure(.responseShapeMismatch)
      )
      return true
    }

    condition.lock()
    if activeQuery?.channel == frame.channel, activeQuery?.outcome == nil {
      activeQuery?.outcome = .failure(.unexpectedSameChannelTraffic)
      activeQuery?.responseConsumed = true
      condition.broadcast()
      condition.unlock()
      return true
    }
    if drainingResponseChannels.remove(frame.channel) != nil {
      condition.unlock()
      return true
    }
    condition.unlock()
    return false
  }

  private func performQuery(
    payload: [UInt8],
    channel: UInt64,
    send: (BuildServiceRawFrame) throws -> Void
  ) -> QueryOutcome {
    condition.lock()
    activeQuery = ActiveQuery(channel: channel)
    condition.unlock()

    do {
      try send(BuildServiceRawFrame(channel: channel, payload: payload))
    } catch {
      clearActiveQuery()
      return .failure(.requestSendFailed)
    }
    return waitForActiveQuery()
  }

  private func completeServiceResponse(on channel: UInt64, outcome: QueryOutcome) {
    condition.lock()
    if activeQuery?.channel == channel {
      if activeQuery?.outcome == nil {
        activeQuery?.outcome = outcome
      }
      activeQuery?.responseConsumed = true
      condition.broadcast()
    } else {
      drainingResponseChannels.remove(channel)
    }
    condition.unlock()
  }

  private func waitForActiveQuery() -> QueryOutcome {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    while activeQuery?.outcome == nil {
      if !condition.wait(until: deadline) {
        activeQuery?.outcome = .failure(.timeout)
        break
      }
    }
    let query = activeQuery
    activeQuery = nil
    if let query, !query.responseConsumed {
      drainingResponseChannels.insert(query.channel)
    }
    condition.unlock()
    return query?.outcome ?? .failure(.timeout)
  }

  private func clearActiveQuery() {
    condition.lock()
    activeQuery = nil
    condition.unlock()
  }

  private func sharedValuesDisagree(_ valuesByTarget: [[String]]) -> Bool {
    guard let first = valuesByTarget.first, valuesByTarget.count > 1 else { return false }
    for keyIndex in evaluationKeys.indices
    where !Self.targetScopedKeys.contains(evaluationKeys[keyIndex]) {
      if valuesByTarget.dropFirst().contains(where: { $0[keyIndex] != first[keyIndex] }) {
        return true
      }
    }
    return false
  }

  private func requiredPlanRoleIsMissing(in values: [String]) -> Bool {
    zip(evaluationKeys, values).contains {
      Self.requiredPlanRoleKeys.contains($0.0) && $0.1.isEmpty
    }
  }

  private func previewStateDisagrees(
    request: CreateBuildRequest,
    valuesByTarget: [[String]]
  ) -> Bool {
    let isPreviewCommand: Bool
    if case .preview = request.request.buildCommand {
      isPreviewCommand = true
    } else {
      isPreviewCommand = false
    }
    guard let previewIndex = evaluationKeys.firstIndex(of: "ENABLE_PREVIEWS") else {
      return isPreviewCommand
    }
    return valuesByTarget.contains { values in
      (values[previewIndex] == "YES") != isPreviewCommand
    }
  }

  private func writeReport(
    status: EvaluatedSettingsProbeStatus,
    failures: [EvaluatedSettingsProbeFailureCode],
    targetCount: Int,
    targets: [EvaluatedSettingsProbeTargetReport]
  ) {
    condition.lock()
    guard !hasWrittenReport else {
      condition.unlock()
      return
    }
    hasWrittenReport = true
    condition.unlock()
    try? reportWriter.write(
      EvaluatedSettingsProbeReport(
        schemaVersion: 1,
        status: status,
        failureCodes: failures,
        targetCount: targetCount,
        targets: targets
      )
    )
  }

  private func appendUnique(
    _ failure: EvaluatedSettingsProbeFailureCode,
    to failures: inout [EvaluatedSettingsProbeFailureCode]
  ) {
    if !failures.contains(failure) {
      failures.append(failure)
    }
  }

  private static func loadEnvironmentKeys(from manifestURL: URL) throws -> [String] {
    let data = try readBoundedRegularFile(at: manifestURL)
    let manifest: SettingsProbeManifest
    do {
      manifest = try JSONDecoder().decode(
        SettingsProbeManifest.self,
        from: data
      )
    } catch {
      throw EvaluatedSettingsProbeConfigurationError.malformedManifest
    }
    guard manifest.schemaVersion == 2 else {
      throw EvaluatedSettingsProbeConfigurationError.unsupportedManifestSchema(
        manifest.schemaVersion)
    }
    guard manifest.invocation.environmentKeys.count <= maximumEnvironmentKeyCount else {
      throw EvaluatedSettingsProbeConfigurationError.tooManyEnvironmentKeys
    }

    var seen: Set<String> = []
    for key in manifest.invocation.environmentKeys {
      guard isValidMacroName(key) else {
        throw EvaluatedSettingsProbeConfigurationError.invalidEnvironmentKey(key)
      }
      guard seen.insert(key).inserted else {
        throw EvaluatedSettingsProbeConfigurationError.duplicateEnvironmentKey(key)
      }
    }
    return manifest.invocation.environmentKeys
  }

  private static func readBoundedRegularFile(at url: URL) throws -> Data {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw EvaluatedSettingsProbeConfigurationError.manifestNotRegularFile
    }
    defer { Darwin.close(descriptor) }

    var fileStatus = stat()
    guard fstat(descriptor, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG
    else {
      throw EvaluatedSettingsProbeConfigurationError.manifestNotRegularFile
    }
    guard fileStatus.st_size >= 0,
      fileStatus.st_size <= maximumManifestBytes
    else {
      throw EvaluatedSettingsProbeConfigurationError.manifestTooLarge
    }

    var data = Data()
    data.reserveCapacity(Int(fileStatus.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw EvaluatedSettingsProbeConfigurationError.malformedManifest
      }
      if count == 0 { break }
      guard data.count + count <= maximumManifestBytes else {
        throw EvaluatedSettingsProbeConfigurationError.manifestTooLarge
      }
      data.append(buffer, count: count)
    }
    guard data.count <= maximumManifestBytes else {
      throw EvaluatedSettingsProbeConfigurationError.manifestTooLarge
    }
    return data
  }

  private static func isValidMacroName(_ value: String) -> Bool {
    guard let first = value.utf8.first, isASCIILetter(first) || first == 95 else {
      return false
    }
    return value.utf8.dropFirst().allSatisfy {
      isASCIILetter($0) || $0 == 95 || ($0 >= 48 && $0 <= 57)
    }
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  }
}
