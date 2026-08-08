import BazelProxyCore
import Foundation
import ModernBuildServiceProxyCore
import SWBProtocol

public enum BazelBuildServiceRouterConfigurationError: LocalizedError, Equatable {
  case incompleteEnvironment
  case invalidProjectContainer(String)

  public var errorDescription: String? {
    switch self {
    case .incompleteEnvironment:
      return "The Bazel build proxy requires manifest, SHA-256, and project identity together."
    case .invalidProjectContainer(let path):
      return "The Bazel build proxy manifest is not inside its generated Xcode project: \(path)"
    }
  }
}

public enum BazelBuildServiceRouterProtocolError: LocalizedError, Equatable {
  case clientChannelReuse(UInt64)
  case nativeNegativeOperationID(Int)
  case nativeOperationCollision(Int)
  case oversizedNativeControl(channel: UInt64, messageName: String?)
  case unexpectedNativeResponse(channel: UInt64, messageName: String?)

  public var errorDescription: String? {
    switch self {
    case .clientChannelReuse(let channel):
      return "The build client reused active protocol channel \(channel)."
    case .nativeNegativeOperationID(let id):
      return "The pinned native build service returned reserved negative operation ID \(id)."
    case .nativeOperationCollision(let id):
      return "The native build service returned colliding operation identity \(id)."
    case .oversizedNativeControl(let channel, let messageName):
      return
        "The native build service returned oversized control traffic on channel \(channel): \(messageName ?? "unknown")."
    case .unexpectedNativeResponse(let channel, let messageName):
      return
        "The native build service returned unexpected traffic on one-shot channel \(channel): \(messageName ?? "unknown")."
    }
  }
}

public struct BazelBuildServiceRouterConfiguration: Sendable {
  public static let manifestEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_MANIFEST"
  public static let manifestSHA256EnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_MANIFEST_SHA256"
  public static let projectIdentityEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_PROJECT_IDENTITY"

  public let manifestURL: URL
  public let verifiedManifest: VerifiedBuildProxyManifest

  public init(manifestURL: URL, verifiedManifest: VerifiedBuildProxyManifest) {
    self.manifestURL = manifestURL
    self.verifiedManifest = verifiedManifest
  }

  public static func loadIfEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Self? {
    let manifestPath = nonempty(environment[manifestEnvironmentKey])
    let manifestSHA256 = nonempty(environment[manifestSHA256EnvironmentKey])
    let projectIdentity = nonempty(environment[projectIdentityEnvironmentKey])
    if manifestPath == nil, manifestSHA256 == nil, projectIdentity == nil {
      return nil
    }
    guard let manifestPath, let manifestSHA256, let projectIdentity else {
      throw BazelBuildServiceRouterConfigurationError.incompleteEnvironment
    }

    let manifestURL = URL(fileURLWithPath: manifestPath, isDirectory: false).standardizedFileURL
    let projectContainerURL =
      manifestURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .standardizedFileURL
    guard projectContainerURL.pathExtension == "xcodeproj" else {
      throw BazelBuildServiceRouterConfigurationError.invalidProjectContainer(manifestPath)
    }
    let verifiedManifest = try BuildProxyManifest.loadVerified(
      from: manifestURL,
      expecting: BuildProxyManifestExpectation(
        projectContainerURL: projectContainerURL,
        projectIdentity: projectIdentity
      ),
      expectedSHA256: manifestSHA256
    )
    return Self(manifestURL: manifestURL, verifiedManifest: verifiedManifest)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

private enum ExportedSettingsQueryOutcome {
  case failure(String)
  case values([String: String])
}

private struct ActiveExportedSettingsQuery {
  let channel: UInt64
  var outcome: ExportedSettingsQueryOutcome?
}

private enum OwnedOperationState: Equatable {
  case pending
  case publishing
  case running
  case cancelling
  case terminalReserved(ProxyTerminalStatus)
  case terminal
}

extension OwnedOperationState {
  fileprivate var holdsBuildClassCapacity: Bool {
    switch self {
    case .pending, .publishing, .running, .cancelling: true
    case .terminalReserved, .terminal: false
    }
  }
}

private enum BuildOperationClass: Equatable {
  case buildDescription
  case index
  case normal
}

extension BuildOperationClass {
  fileprivate var description: String {
    switch self {
    case .buildDescription: "build-description"
    case .index: "index"
    case .normal: "normal"
    }
  }
}

private struct NativePendingBuild {
  let eventChannel: UInt64
  let operationClass: BuildOperationClass
  let sessionHandle: String
}

private struct NativeActiveBuild {
  let eventChannel: UInt64
  let operationClass: BuildOperationClass
  let sessionHandle: String
}

private struct OwnedOperationPresentation: Sendable {
  let targetIDsByGUID: [String: Int]
  let wrapperTaskID: Int
  let wrapperTaskSignature: String
  var nextTaskID: Int
}

private struct OwnedBuildOperation {
  let operationClass: BuildOperationClass
  let plan: ResolvedBuildPlan
  let protocolID: Int
  let responseChannel: UInt64
  let sessionHandle: String
  let outputs: BuildServiceFrameOutputs
  var executionTask: Task<Void, Never>?
  var clientReadyForLifecycleEvents: Bool
  var inFlightEventCount: Int
  var presentation: OwnedOperationPresentation
  var state: OwnedOperationState
}

private struct ResolvingBuildOperation {
  let eventChannel: UInt64
  let operationClass: BuildOperationClass
  let sessionHandle: String
  var task: Task<Void, Never>?
}

private struct HeldDeleteSessionRequest {
  let frame: BuildServiceRawFrame
  let outputs: BuildServiceFrameOutputs
  let sessionHandle: String
}

/// Routes only manifest-owned build operations to Bazel while preserving the native service for
/// every unsupported, ignored, or unrelated operation.
public final class BazelBuildServiceRouter: BuildServiceFrameInterceptor, @unchecked Sendable {
  private static let auxiliaryChannelLowerBound = UInt64(1) << 63

  private let condition = NSCondition()
  private let configuration: BazelBuildServiceRouterConfiguration
  private let executor: any BazelOperationExecuting
  private let operationDirectoryNamespace = UUID().uuidString.lowercased()
  private let processEnvironment: [String: String]
  private let queryTimeout: TimeInterval

  private var activeQueries = [UInt64: ActiveExportedSettingsQuery]()
  private var activeAsyncTaskCount = 0
  private var deletingSessions = Set<String>()
  private var drainingResponseChannels = Set<UInt64>()
  private var everEventChannels = Set<UInt64>()
  private var everPrivateChannels = Set<UInt64>()
  private var heldDeleteRequests = [HeldDeleteSessionRequest]()
  private var isShuttingDown = false
  private var deleteSessionsByRequestChannel = [UInt64: String]()
  private var nativeActiveBuilds = [Int: NativeActiveBuild]()
  private var nativeBuildIDsByEventChannel = [UInt64: Int]()
  private var nativePendingBuildsByRequestChannel = [UInt64: NativePendingBuild]()
  private var nextAuxiliaryChannel: UInt64? = .max
  private var nextOperationSequence: UInt64 = 1
  private var nextProtocolOperationID = -1
  private var observedChannels = Set<UInt64>()
  private var operations = [Int: OwnedBuildOperation]()
  private var resolvingBuildsByRequestChannel = [UInt64: ResolvingBuildOperation]()

  public init(
    configuration: BazelBuildServiceRouterConfiguration,
    executor: any BazelOperationExecuting = BazelOperationExecutor(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    queryTimeout: TimeInterval = 5
  ) {
    self.configuration = configuration
    self.executor = executor
    self.processEnvironment = processEnvironment
    self.queryTimeout = max(0, queryTimeout)
  }

  deinit {
    condition.lock()
    isShuttingDown = true
    for channel in activeQueries.keys where activeQueries[channel]?.outcome == nil {
      activeQueries[channel]?.outcome = .failure("The build-service proxy is shutting down.")
    }
    let tasks =
      operations.values.compactMap(\.executionTask)
      + resolvingBuildsByRequestChannel.values.compactMap(\.task)
    condition.broadcast()
    condition.unlock()
    for task in tasks {
      task.cancel()
    }
  }

  public func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    condition.lock()
    observedChannels.insert(channel)
    let result: Bool
    switch direction {
    case .clientToService:
      result =
        everPrivateChannels.contains(channel)
        || isUnavailablePublicClientChannelLocked(channel)
        || [
          CreateBuildRequest.name,
          BuildStartRequest.name,
          BuildCancelRequest.name,
          DeleteSessionRequest.name,
        ].contains(messageName)
    case .serviceToClient:
      result =
        everPrivateChannels.contains(channel)
        || nativePendingBuildsByRequestChannel[channel] != nil
        || (nativeBuildIDsByEventChannel[channel] != nil
          && (messageName == BuildOperationEnded.name || messageName == ErrorResponse.name))
        || deleteSessionsByRequestChannel[channel] != nil
    }
    condition.unlock()
    return result
  }

  public func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    switch direction {
    case .clientToService:
      if isPrivateChannel(frame.channel) {
        try sendError(
          "The build request reused a proxy-owned protocol channel.",
          channel: frame.channel,
          outputs: outputs
        )
        return true
      }
      if isUnavailablePublicClientChannel(frame.channel) {
        throw BazelBuildServiceRouterProtocolError.clientChannelReuse(frame.channel)
      }
      switch frame.messageName {
      case CreateBuildRequest.name:
        return try handleCreateBuild(frame, outputs: outputs)
      case BuildStartRequest.name:
        return try handleBuildStart(frame, outputs: outputs)
      case BuildCancelRequest.name:
        return try handleBuildCancel(frame, outputs: outputs)
      case DeleteSessionRequest.name:
        return try handleDeleteSession(frame, outputs: outputs)
      default:
        return false
      }
    case .serviceToClient:
      return try handleServiceResponse(frame)
    }
  }

  public func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) throws -> Bool {
    guard direction == .serviceToClient else {
      // No ownership decision was possible, so preserve native behavior byte-for-byte.
      return false
    }
    condition.lock()
    let isPrivateChannel = everPrivateChannels.contains(channel)
    if isPrivateChannel, activeQueries[channel] != nil {
      activeQueries[channel]?.outcome = .failure(
        "The exported-settings response exceeded the capture limit."
      )
      condition.broadcast()
    } else if isPrivateChannel {
      drainingResponseChannels.remove(channel)
    } else if nativePendingBuildsByRequestChannel.removeValue(forKey: channel) != nil {
      condition.unlock()
      throw BazelBuildServiceRouterProtocolError.oversizedNativeControl(
        channel: channel,
        messageName: messageName
      )
    } else if let nativeID = nativeBuildIDsByEventChannel.removeValue(forKey: channel) {
      nativeActiveBuilds.removeValue(forKey: nativeID)
      condition.unlock()
      throw BazelBuildServiceRouterProtocolError.oversizedNativeControl(
        channel: channel,
        messageName: messageName
      )
    } else if let sessionHandle = deleteSessionsByRequestChannel.removeValue(forKey: channel) {
      clearSessionLocked(sessionHandle)
      condition.unlock()
      throw BazelBuildServiceRouterProtocolError.oversizedNativeControl(
        channel: channel,
        messageName: messageName
      )
    }
    condition.unlock()
    return isPrivateChannel
  }

  /// Stops accepting output, wakes any settings waiter, and requests cancellation for every
  /// proxy-owned adapter process. Native operations remain owned by the native service.
  public func shutdown() {
    condition.lock()
    guard !isShuttingDown else {
      condition.unlock()
      return
    }
    isShuttingDown = true
    for channel in activeQueries.keys where activeQueries[channel]?.outcome == nil {
      activeQueries[channel]?.outcome = .failure("The build-service proxy is shutting down.")
    }
    var pendingOperations = [OwnedBuildOperation]()
    for (id, var operation) in operations {
      switch operation.state {
      case .pending:
        operation.state = .terminalReserved(.cancelled)
        operations[id] = operation
        pendingOperations.append(operation)
      case .publishing:
        operation.state = .terminalReserved(.cancelled)
        operations[id] = operation
      case .running:
        operation.state = .cancelling
        operations[id] = operation
      case .cancelling, .terminalReserved, .terminal:
        break
      }
    }
    activeAsyncTaskCount += pendingOperations.count
    let tasks =
      operations.values.compactMap(\.executionTask)
      + resolvingBuildsByRequestChannel.values.compactMap(\.task)
    heldDeleteRequests.removeAll()
    condition.broadcast()
    condition.unlock()
    for task in tasks {
      task.cancel()
    }
    condition.lock()
    condition.broadcast()
    condition.unlock()
    for operation in pendingOperations {
      Task<Void, Never> { [self] in
        defer { asyncTaskDidFinish() }
        try? sendPreStartCancellation(operation)
        _ = completeReservedOperation(
          operation.protocolID,
          sessionHandle: operation.sessionHandle
        )
      }
    }
  }

  public func buildServiceRelayWillClose() {
    shutdown()
  }

  public func buildServiceRelayWaitForQuiescence(timeout: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: max(0, timeout))
    condition.lock()
    while !activeQueries.isEmpty || activeAsyncTaskCount > 0 {
      if !condition.wait(until: deadline) {
        condition.unlock()
        return false
      }
    }
    condition.unlock()
    return true
  }

  private func handleCreateBuild(
    _ frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    guard let request = try? SwiftBuildProtocolCodec.decodeCreateBuild(frame.payload) else {
      return false
    }
    guard
      validateAndReserveCreateChannels(
        requestChannel: frame.channel,
        eventChannel: request.responseChannel
      )
    else {
      try sendError(
        "The build request uses a colliding or invalid protocol channel.",
        channel: frame.channel,
        outputs: outputs
      )
      return true
    }

    condition.lock()
    let sessionIsDeleting = deletingSessions.contains(request.sessionHandle)
    let shuttingDown = isShuttingDown
    condition.unlock()
    if sessionIsDeleting || shuttingDown {
      try sendRegistrationError(
        "The build session is no longer accepting operations.",
        requestChannel: frame.channel,
        eventChannel: request.responseChannel,
        outputs: outputs
      )
      return true
    }

    let operationClass = Self.operationClass(for: request)
    if operationClass == .buildDescription {
      registerNativePendingBuild(
        requestChannel: frame.channel,
        request: request,
        operationClass: operationClass
      )
      return false
    }
    if hasProxyConflict(sessionHandle: request.sessionHandle, operationClass: operationClass)
      || hasResolvingConflict(
        sessionHandle: request.sessionHandle,
        operationClass: operationClass,
        excludingRequestChannel: nil
      )
    {
      try sendRegistrationError(
        "Unexpected attempt to have multiple concurrent \(operationClass.description) build operations.",
        requestChannel: frame.channel,
        eventChannel: request.responseChannel,
        outputs: outputs
      )
      return true
    }
    if hasNativeConflict(sessionHandle: request.sessionHandle, operationClass: operationClass) {
      registerNativePendingBuild(
        requestChannel: frame.channel,
        request: request,
        operationClass: operationClass
      )
      return false
    }

    condition.lock()
    resolvingBuildsByRequestChannel[frame.channel] = ResolvingBuildOperation(
      eventChannel: request.responseChannel,
      operationClass: operationClass,
      sessionHandle: request.sessionHandle,
      task: nil
    )
    activeAsyncTaskCount += 1
    condition.unlock()
    let task = Task<Void, Never> { [self] in
      defer { asyncTaskDidFinish() }
      self.resolveCreateBuild(
        frame,
        request: request,
        operationClass: operationClass,
        outputs: outputs
      )
    }
    condition.lock()
    if resolvingBuildsByRequestChannel[frame.channel] != nil, !isShuttingDown {
      resolvingBuildsByRequestChannel[frame.channel]?.task = task
    } else {
      task.cancel()
    }
    condition.unlock()
    return true
  }

  private func handleBuildStart(
    _ frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    guard let request = try? SwiftBuildProtocolCodec.decodeBuildStart(frame.payload) else {
      return false
    }
    guard !isPrivateChannel(frame.channel) else {
      try sendError(
        "The build request reused a proxy-owned protocol channel.",
        channel: frame.channel,
        outputs: outputs
      )
      return true
    }
    condition.lock()
    if var operation = operations[request.id],
      operation.sessionHandle == request.sessionHandle
    {
      operation.clientReadyForLifecycleEvents = true
      operations[request.id] = operation
    }
    while let operation = operations[request.id],
      operation.sessionHandle == request.sessionHandle,
      operation.state == .publishing,
      !isShuttingDown
    {
      condition.wait()
    }
    guard var operation = operations[request.id] else {
      condition.unlock()
      return false
    }
    guard operation.sessionHandle == request.sessionHandle,
      operation.state == .pending,
      !deletingSessions.contains(request.sessionHandle),
      !isShuttingDown
    else {
      condition.unlock()
      if operation.sessionHandle != request.sessionHandle { return false }
      try sendError(
        "The Bazel build operation cannot be started in its current state.",
        channel: frame.channel,
        outputs: outputs
      )
      return true
    }
    operation.state = .running
    operation.inFlightEventCount += 1
    operations[request.id] = operation
    activeAsyncTaskCount += 1
    condition.unlock()

    do {
      try outputs.sendToXcode(
        BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildOperationPresenter.encodeVoidResponse()
        )
      )
      try emitOperationPrefix(operation, outputs: outputs)
    } catch {
      eventDidFinish(operationID: request.id)
      asyncTaskDidFinish()
      throw error
    }
    eventDidFinish(operationID: request.id)

    let executionTask = Task<Void, Never> { [self] in
      defer { asyncTaskDidFinish() }
      await self.run(operationID: request.id, outputs: outputs)
    }
    condition.lock()
    if operations[request.id]?.state == .running, !isShuttingDown {
      operations[request.id]?.executionTask = executionTask
    } else {
      executionTask.cancel()
    }
    condition.unlock()
    return true
  }

  private func resolveCreateBuild(
    _ frame: BuildServiceRawFrame,
    request: CreateBuildRequest,
    operationClass: BuildOperationClass,
    outputs: BuildServiceFrameOutputs
  ) {
    var snapshots = [PerTargetExportedSettingsSnapshot]()
    for configuredTarget in request.request.configuredTargets {
      guard !Task.isCancelled, let channel = allocateAuxiliaryChannel() else {
        failResolvingCreate(
          frame,
          request: request,
          message: Task.isCancelled
            ? "The build request was cancelled while resolving settings."
            : "The build proxy could not reserve an exported-settings channel.",
          outputs: outputs
        )
        return
      }
      let payload = SwiftBuildProtocolCodec.encodeAllExportedMacrosAndValuesRequest(
        sessionHandle: request.sessionHandle,
        targetGUID: configuredTarget.guid,
        buildParameters: configuredTarget.parameters ?? request.request.parameters
      )
      switch performSettingsQuery(
        payload: payload,
        channel: channel,
        outputs: outputs
      ) {
      case .values(let values):
        snapshots.append(
          PerTargetExportedSettingsSnapshot(
            targetGUID: configuredTarget.guid,
            exportedValues: values,
            verifiedManifest: configuration.verifiedManifest
          )
        )
      case .failure(let message):
        failResolvingCreate(
          frame,
          request: request,
          message: message,
          outputs: outputs
        )
        return
      }
    }

    guard !Task.isCancelled else {
      failResolvingCreate(
        frame,
        request: request,
        message: "The build request was cancelled while resolving settings.",
        outputs: outputs
      )
      return
    }
    let decision = ResolvedBuildPlanBuilder.resolve(
      operationID: allocateOperationDirectoryIdentity(),
      request: request,
      manifestURL: configuration.manifestURL,
      verifiedManifest: configuration.verifiedManifest,
      settingsSnapshots: snapshots
    )
    switch decision {
    case .forwardNative:
      finishResolvingByForwardingNative(
        frame,
        request: request,
        operationClass: operationClass,
        outputs: outputs
      )
    case .reject(let rejection):
      failResolvingCreate(
        frame,
        request: request,
        message: rejection.localizedDescription,
        outputs: outputs
      )
    case .intercept(let plan):
      finishResolvingWithOwnedBuild(
        frame,
        request: request,
        plan: plan,
        outputs: outputs
      )
    }
  }

  private func finishResolvingByForwardingNative(
    _ frame: BuildServiceRawFrame,
    request: CreateBuildRequest,
    operationClass: BuildOperationClass,
    outputs: BuildServiceFrameOutputs
  ) {
    condition.lock()
    guard resolvingBuildsByRequestChannel[frame.channel] != nil else {
      condition.unlock()
      return
    }
    let closing = deletingSessions.contains(request.sessionHandle) || isShuttingDown
    if closing {
      resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
      let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
      condition.broadcast()
      condition.unlock()
      try? sendRegistrationError(
        "The build session is no longer accepting operations.",
        requestChannel: frame.channel,
        eventChannel: request.responseChannel,
        outputs: outputs
      )
      try? forwardDeleteRequests(ready)
    } else {
      nativePendingBuildsByRequestChannel[frame.channel] = NativePendingBuild(
        eventChannel: request.responseChannel,
        operationClass: operationClass,
        sessionHandle: request.sessionHandle
      )
      condition.unlock()
      do {
        try outputs.sendToNative(frame)
      } catch {
        condition.lock()
        nativePendingBuildsByRequestChannel.removeValue(forKey: frame.channel)
        resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
        let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
        condition.broadcast()
        condition.unlock()
        try? forwardDeleteRequests(ready)
        return
      }
      condition.lock()
      resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
      let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
      condition.broadcast()
      condition.unlock()
      try? forwardDeleteRequests(ready)
    }
  }

  private func finishResolvingWithOwnedBuild(
    _ frame: BuildServiceRawFrame,
    request: CreateBuildRequest,
    plan: ResolvedBuildPlan,
    outputs: BuildServiceFrameOutputs
  ) {
    let proxyOperationClass: BuildOperationClass =
      plan.intent.action == .indexBuild
      ? .index : .normal
    if hasNativeConflict(
      sessionHandle: request.sessionHandle,
      operationClass: proxyOperationClass
    ) {
      finishResolvingByForwardingNative(
        frame,
        request: request,
        operationClass: Self.operationClass(for: request),
        outputs: outputs
      )
      return
    }
    guard let protocolID = allocateProtocolOperationID() else {
      failResolvingCreate(
        frame,
        request: request,
        message: "The build proxy exhausted its operation identity space.",
        outputs: outputs
      )
      return
    }
    let presentation = makePresentation(for: plan)
    condition.lock()
    guard resolvingBuildsByRequestChannel[frame.channel] != nil,
      !isShuttingDown,
      !deletingSessions.contains(request.sessionHandle)
    else {
      condition.unlock()
      failResolvingCreate(
        frame,
        request: request,
        message: "The build session is no longer accepting operations.",
        outputs: outputs
      )
      return
    }
    operations[protocolID] = OwnedBuildOperation(
      operationClass: proxyOperationClass,
      plan: plan,
      protocolID: protocolID,
      responseChannel: request.responseChannel,
      sessionHandle: request.sessionHandle,
      outputs: outputs,
      executionTask: nil,
      clientReadyForLifecycleEvents: false,
      inFlightEventCount: 0,
      presentation: presentation,
      state: .publishing
    )
    condition.unlock()
    do {
      try outputs.sendToXcode(
        BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildOperationPresenter.encodeBuildCreated(id: protocolID)
        )
      )
    } catch {
      condition.lock()
      operations.removeValue(forKey: protocolID)
      resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
      let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
      condition.broadcast()
      condition.unlock()
      try? forwardDeleteRequests(ready)
      return
    }
    condition.lock()
    resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
    let cancellationReserved: OwnedBuildOperation?
    if let operation = operations[protocolID],
      operation.state == .terminalReserved(.cancelled)
    {
      cancellationReserved = operation
    } else {
      cancellationReserved = nil
    }
    if operations[protocolID]?.state == .publishing {
      operations[protocolID]?.state = .pending
    }
    condition.broadcast()
    condition.unlock()
    if let cancellationReserved {
      try? sendPreStartCancellation(cancellationReserved)
      let ready = completeReservedOperation(
        protocolID,
        sessionHandle: request.sessionHandle
      )
      try? forwardDeleteRequests(ready)
    }
  }

  private func failResolvingCreate(
    _ frame: BuildServiceRawFrame,
    request: CreateBuildRequest,
    message: String,
    outputs: BuildServiceFrameOutputs
  ) {
    try? sendRegistrationError(
      message,
      requestChannel: frame.channel,
      eventChannel: request.responseChannel,
      outputs: outputs
    )
    condition.lock()
    resolvingBuildsByRequestChannel.removeValue(forKey: frame.channel)
    let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
    condition.broadcast()
    condition.unlock()
    try? forwardDeleteRequests(ready)
  }

  private func handleBuildCancel(
    _ frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    guard let request = try? SwiftBuildProtocolCodec.decodeBuildCancel(frame.payload) else {
      return false
    }
    guard !isPrivateChannel(frame.channel) else {
      try sendError(
        "The build request reused a proxy-owned protocol channel.",
        channel: frame.channel,
        outputs: outputs
      )
      return true
    }
    condition.lock()
    guard var operation = operations[request.id] else {
      condition.unlock()
      return false
    }
    guard operation.sessionHandle == request.sessionHandle else {
      condition.unlock()
      return false
    }
    operation.clientReadyForLifecycleEvents = true
    operations[request.id] = operation
    let task: Task<Void, Never>?
    let cancelBeforeStart: Bool
    switch operation.state {
    case .pending:
      cancelBeforeStart = true
      operation.state = .terminalReserved(.cancelled)
      operations[request.id] = operation
      task = nil
    case .publishing:
      cancelBeforeStart = false
      operation.state = .terminalReserved(.cancelled)
      operations[request.id] = operation
      task = nil
    case .running:
      cancelBeforeStart = false
      operation.state = .cancelling
      operations[request.id] = operation
      task = operation.executionTask
    case .cancelling, .terminalReserved, .terminal:
      cancelBeforeStart = false
      task = nil
    }
    condition.unlock()

    try outputs.sendToXcode(
      BuildServiceRawFrame(
        channel: frame.channel,
        payload: SwiftBuildOperationPresenter.encodeVoidResponse()
      )
    )
    if cancelBeforeStart {
      try sendPreStartCancellation(operation)
      let ready = completeReservedOperation(
        request.id,
        sessionHandle: operation.sessionHandle
      )
      try forwardDeleteRequests(ready)
    }
    task?.cancel()
    return true
  }

  private func handleDeleteSession(
    _ frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    guard let request = try? SwiftBuildProtocolCodec.decodeDeleteSession(frame.payload) else {
      return false
    }
    guard !isPrivateChannel(frame.channel) else {
      try sendError(
        "The build request reused a proxy-owned protocol channel.",
        channel: frame.channel,
        outputs: outputs
      )
      return true
    }
    condition.lock()
    deleteSessionsByRequestChannel[frame.channel] = request.sessionHandle
    let ownedIDs = operations.values
      .filter { $0.sessionHandle == request.sessionHandle }
      .map(\.protocolID)
    let resolvingTasks = resolvingBuildsByRequestChannel.values
      .filter { $0.sessionHandle == request.sessionHandle }
      .compactMap(\.task)
    guard !ownedIDs.isEmpty || !resolvingTasks.isEmpty else {
      condition.unlock()
      return false
    }
    deletingSessions.insert(request.sessionHandle)
    var tasks = [Task<Void, Never>]()
    var pendingOperations = [OwnedBuildOperation]()
    for id in ownedIDs {
      guard let operation = operations[id] else { continue }
      switch operation.state {
      case .pending:
        var cancellingOperation = operation
        cancellingOperation.state = .terminalReserved(.cancelled)
        operations[id] = cancellingOperation
        pendingOperations.append(operation)
      case .publishing:
        var cancellingOperation = operation
        cancellingOperation.state = .terminalReserved(.cancelled)
        operations[id] = cancellingOperation
      case .running:
        var cancellingOperation = operation
        cancellingOperation.state = .cancelling
        operations[id] = cancellingOperation
        if let task = operation.executionTask { tasks.append(task) }
      case .cancelling:
        if let task = operation.executionTask { tasks.append(task) }
      case .terminalReserved:
        if let task = operation.executionTask { tasks.append(task) }
      case .terminal:
        break
      }
    }
    heldDeleteRequests.append(
      HeldDeleteSessionRequest(
        frame: frame,
        outputs: outputs,
        sessionHandle: request.sessionHandle
      )
    )
    let ready = takeReadyDeleteRequestsLocked(for: request.sessionHandle)
    condition.broadcast()
    condition.unlock()

    tasks.append(contentsOf: resolvingTasks)
    for task in tasks {
      task.cancel()
    }
    condition.lock()
    condition.broadcast()
    condition.unlock()
    var readyDeletes = ready
    for operation in pendingOperations {
      try sendPreStartCancellation(operation)
      readyDeletes.append(
        contentsOf: completeReservedOperation(
          operation.protocolID,
          sessionHandle: operation.sessionHandle
        )
      )
    }
    try forwardDeleteRequests(readyDeletes)
    return true
  }

  private func handleServiceResponse(_ frame: BuildServiceRawFrame) throws -> Bool {
    condition.lock()
    if let pending = nativePendingBuildsByRequestChannel[frame.channel] {
      condition.unlock()
      if frame.messageName == BuildCreated.name {
        let created = try SwiftBuildProtocolCodec.decodeBuildCreated(frame.payload)
        guard created.id >= 0 else {
          throw BazelBuildServiceRouterProtocolError.nativeNegativeOperationID(created.id)
        }
        condition.lock()
        guard operations[created.id] == nil, nativeActiveBuilds[created.id] == nil,
          nativeBuildIDsByEventChannel[pending.eventChannel] == nil
        else {
          condition.unlock()
          throw BazelBuildServiceRouterProtocolError.nativeOperationCollision(created.id)
        }
        nativePendingBuildsByRequestChannel.removeValue(forKey: frame.channel)
        nativeActiveBuilds[created.id] = NativeActiveBuild(
          eventChannel: pending.eventChannel,
          operationClass: pending.operationClass,
          sessionHandle: pending.sessionHandle
        )
        nativeBuildIDsByEventChannel[pending.eventChannel] = created.id
        condition.unlock()
        return false
      }
      if frame.messageName == ErrorResponse.name {
        condition.lock()
        nativePendingBuildsByRequestChannel.removeValue(forKey: frame.channel)
        condition.unlock()
        return false
      }
      condition.lock()
      nativePendingBuildsByRequestChannel.removeValue(forKey: frame.channel)
      condition.unlock()
      throw BazelBuildServiceRouterProtocolError.unexpectedNativeResponse(
        channel: frame.channel,
        messageName: frame.messageName
      )
    }
    if let nativeID = nativeBuildIDsByEventChannel[frame.channel] {
      condition.unlock()
      if frame.messageName == BuildOperationEnded.name {
        let ended = try SwiftBuildProtocolCodec.decodeBuildOperationEnded(frame.payload)
        guard ended.id == nativeID else {
          throw BazelBuildServiceRouterProtocolError.nativeOperationCollision(ended.id)
        }
      }
      if frame.messageName == BuildOperationEnded.name || frame.messageName == ErrorResponse.name {
        condition.lock()
        nativeBuildIDsByEventChannel.removeValue(forKey: frame.channel)
        nativeActiveBuilds.removeValue(forKey: nativeID)
        condition.unlock()
      }
      return false
    }
    if let sessionHandle = deleteSessionsByRequestChannel[frame.channel] {
      if frame.messageName == VoidResponse.name || frame.messageName == ErrorResponse.name {
        deleteSessionsByRequestChannel.removeValue(forKey: frame.channel)
        clearSessionLocked(sessionHandle)
        condition.unlock()
        return false
      }
      deleteSessionsByRequestChannel.removeValue(forKey: frame.channel)
      clearSessionLocked(sessionHandle)
      condition.unlock()
      throw BazelBuildServiceRouterProtocolError.unexpectedNativeResponse(
        channel: frame.channel,
        messageName: frame.messageName
      )
    }
    guard activeQueries[frame.channel] != nil else {
      let wasPrivate = everPrivateChannels.contains(frame.channel)
      drainingResponseChannels.remove(frame.channel)
      condition.unlock()
      return wasPrivate
    }
    let keys = settingsKeys()
    condition.unlock()

    let outcome: ExportedSettingsQueryOutcome
    if frame.messageName == AllExportedMacrosAndValuesResponse.name {
      do {
        outcome = .values(
          try SwiftBuildProtocolCodec.decodeAllExportedMacrosAndValuesResponseDictionary(
            frame.payload,
            selecting: keys
          )
        )
      } catch {
        outcome = .failure("The native service returned malformed exported settings.")
      }
    } else if frame.messageName == ErrorResponse.name {
      outcome = .failure("The native service rejected the exported-settings query.")
    } else {
      outcome = .failure("The native service returned unexpected exported-settings traffic.")
    }

    condition.lock()
    if activeQueries[frame.channel]?.outcome == nil {
      activeQueries[frame.channel]?.outcome = outcome
      condition.broadcast()
    }
    condition.unlock()
    return true
  }

  private func performSettingsQuery(
    payload: [UInt8],
    channel: UInt64,
    outputs: BuildServiceFrameOutputs
  ) -> ExportedSettingsQueryOutcome {
    condition.lock()
    activeQueries[channel] = ActiveExportedSettingsQuery(channel: channel, outcome: nil)
    condition.unlock()
    do {
      try outputs.sendToNative(BuildServiceRawFrame(channel: channel, payload: payload))
    } catch {
      condition.lock()
      activeQueries.removeValue(forKey: channel)
      condition.unlock()
      return .failure("The build proxy could not send an exported-settings query.")
    }

    let deadline = Date(timeIntervalSinceNow: queryTimeout)
    condition.lock()
    while activeQueries[channel]?.outcome == nil, !isShuttingDown, !Task.isCancelled {
      if !condition.wait(until: deadline) { break }
    }
    let outcome = activeQueries[channel]?.outcome
    if outcome == nil {
      drainingResponseChannels.insert(channel)
    }
    activeQueries.removeValue(forKey: channel)
    condition.unlock()
    return outcome ?? .failure("The native service timed out while exporting build settings.")
  }

  private func run(operationID: Int, outputs: BuildServiceFrameOutputs) async {
    guard let operation = runningOperation(operationID) else { return }

    let result = await executor.execute(
      plan: operation.plan,
      processEnvironment: processEnvironment
    ) { [weak self] event in
      guard let self else { return }
      try self.emit(event, operationID: operationID, outputs: outputs)
    }

    let terminalStatus = reserveTerminal(
      operationID,
      proposedStatus: result.status
    )
    if let terminalStatus {
      do {
        if terminalStatus == .failed, let failure = result.failure {
          try emitFailure(failure, operation: operation, outputs: outputs)
        }
        try emitOperationSuffix(
          operation,
          status: terminalStatus,
          signalled: Self.wasSignalled(result.processCompletion),
          outputs: outputs
        )
      } catch {
        // The serialized sink latches and reports the first transport failure to the relay.
      }
    }

    let ready = completeOperation(operationID, sessionHandle: operation.sessionHandle)
    try? forwardDeleteRequests(ready)
  }

  private func runningOperation(_ operationID: Int) -> OwnedBuildOperation? {
    condition.lock()
    defer { condition.unlock() }
    guard let operation = operations[operationID],
      operation.state == .running || operation.state == .cancelling
    else {
      return nil
    }
    return operation
  }

  private func reserveTerminal(
    _ operationID: Int,
    proposedStatus: ProxyTerminalStatus
  ) -> ProxyTerminalStatus? {
    condition.lock()
    defer { condition.unlock() }
    while let operation = operations[operationID], operation.inFlightEventCount > 0 {
      condition.wait()
    }
    guard var operation = operations[operationID] else { return nil }
    switch operation.state {
    case .running, .cancelling:
      operation.state = .terminalReserved(proposedStatus)
      operations[operationID] = operation
      return proposedStatus
    case .terminalReserved(let reservedStatus):
      return reservedStatus
    case .pending, .publishing, .terminal:
      return nil
    }
  }

  private func completeOperation(
    _ operationID: Int,
    sessionHandle: String
  ) -> [HeldDeleteSessionRequest] {
    condition.lock()
    if case .terminalReserved? = operations[operationID]?.state {
      operations[operationID]?.state = .terminal
      operations[operationID]?.executionTask = nil
    }
    let ready = takeReadyDeleteRequestsLocked(for: sessionHandle)
    condition.broadcast()
    condition.unlock()
    return ready
  }

  private func completeReservedOperation(
    _ operationID: Int,
    sessionHandle: String
  ) -> [HeldDeleteSessionRequest] {
    condition.lock()
    if case .terminalReserved? = operations[operationID]?.state {
      operations[operationID]?.state = .terminal
      operations[operationID]?.executionTask = nil
    }
    let ready = takeReadyDeleteRequestsLocked(for: sessionHandle)
    condition.broadcast()
    condition.unlock()
    return ready
  }

  private func emitOperationPrefix(
    _ operation: OwnedBuildOperation,
    outputs: BuildServiceFrameOutputs
  ) throws {
    let channel = operation.responseChannel
    try send(
      SwiftBuildOperationPresenter.encodePreparationCompleted(),
      channel: channel,
      outputs: outputs
    )
    try send(
      SwiftBuildOperationPresenter.encodeOperationStarted(id: operation.protocolID),
      channel: channel,
      outputs: outputs
    )
    try send(
      SwiftBuildOperationPresenter.encodePathMap(copied: [:], generated: [:]),
      channel: channel,
      outputs: outputs
    )
    for target in operation.plan.targets {
      guard let id = operation.presentation.targetIDsByGUID[target.mapping.xcodeTargetGUID] else {
        continue
      }
      let requested = operation.plan.intent.requestedTargets.first {
        $0.xcodeTargetGUID == target.mapping.xcodeTargetGUID
      }
      try send(
        SwiftBuildOperationPresenter.encodeTargetStarted(
          SwiftBuildPresentedTarget(
            configurationIsDefault: false,
            configurationName: operation.plan.intent.configuration,
            guid: target.mapping.xcodeTargetGUID,
            id: id,
            name: requested?.targetName ?? target.mapping.product.name,
            project: SwiftBuildPresentedProject(
              isNameUniqueInWorkspace: true,
              isPackage: false,
              name: operation.plan.manifest.project.containerName
                .replacingOccurrences(of: ".xcodeproj", with: ""),
              path: operation.plan.intent.projectContainerURL.path
            ),
            sdkCanonicalName: target.mapping.variant.platform,
            type: .standard
          )
        ),
        channel: channel,
        outputs: outputs
      )
    }
    try send(
      SwiftBuildOperationPresenter.encodeTaskStarted(
        SwiftBuildPresentedTask(
          commandLineDisplayString: nil,
          executionDescription: "Build with Bazel",
          id: operation.presentation.wrapperTaskID,
          interestingPath: nil,
          parentID: nil,
          ruleInfo: "BazelBuild",
          serializedDiagnosticsPaths: [],
          stableSignature: operation.presentation.wrapperTaskSignature,
          targetID: nil,
          taskName: "Bazel"
        )
      ),
      channel: channel,
      outputs: outputs
    )
  }

  private func emit(
    _ event: BazelOperationExecutionEvent,
    operationID: Int,
    outputs: BuildServiceFrameOutputs
  ) throws {
    condition.lock()
    guard var operation = operations[operationID], operation.state == .running,
      !isShuttingDown
    else {
      condition.unlock()
      return
    }
    var actionTaskID: Int?
    if case .bep(.actionCompleted(let action)) = event, action.succeeded != nil {
      actionTaskID = operation.presentation.nextTaskID
      operation.presentation.nextTaskID += 1
    }
    operation.inFlightEventCount += 1
    operations[operationID] = operation
    let channel = operation.responseChannel
    condition.unlock()
    defer { eventDidFinish(operationID: operationID) }

    switch event {
    case .processOutput(let output):
      try send(
        SwiftBuildOperationPresenter.encodeConsoleOutput(
          data: Array(output.bytes),
          taskID: operation.presentation.wrapperTaskID,
          stableSignature: operation.presentation.wrapperTaskSignature
        ),
        channel: channel,
        outputs: outputs
      )
    case .bep(let event):
      switch event {
      case .actionCompleted(let action):
        guard let succeeded = action.succeeded else { return }
        guard let taskID = actionTaskID else { return }
        let signature = "rules_xcodeproj.bazel.action.v1:\(action.identity)"
        let label = action.label.isEmpty ? nil : action.label
        let targetID = label.flatMap { actionLabel in
          operation.plan.targets.first { $0.mapping.bazelLabel == actionLabel }
            .flatMap { operation.presentation.targetIDsByGUID[$0.mapping.xcodeTargetGUID] }
        }
        let actionName = action.mnemonic ?? "Bazel action"
        let ruleInfo = [
          action.mnemonic,
          label,
          action.primaryOutput.isEmpty ? nil : action.primaryOutput,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        try send(
          SwiftBuildOperationPresenter.encodeTaskStarted(
            SwiftBuildPresentedTask(
              commandLineDisplayString: nil,
              executionDescription: actionName,
              id: taskID,
              interestingPath: nil,
              parentID: nil,
              ruleInfo: ruleInfo,
              serializedDiagnosticsPaths: [],
              stableSignature: signature,
              targetID: targetID,
              taskName: actionName
            )
          ),
          channel: channel,
          outputs: outputs
        )
        try send(
          SwiftBuildOperationPresenter.encodeTaskEnded(
            id: taskID,
            stableSignature: signature,
            status: succeeded ? .succeeded : .failed,
            signalled: false
          ),
          channel: channel,
          outputs: outputs
        )
      case .progress(let progress):
        let percent =
          progress.total.map {
            $0 == 0 ? -1 : (Double(progress.completed) / Double($0)) * 100
          } ?? -1
        let message =
          progress.total.map {
            "Bazel actions: \(progress.completed)/\($0)"
          } ?? "Bazel actions completed: \(progress.completed)"
        try send(
          SwiftBuildOperationPresenter.encodeProgressUpdated(
            statusMessage: message,
            percentComplete: percent,
            showInLog: false
          ),
          channel: channel,
          outputs: outputs
        )
      case .reportedExecutedActionCount(let count):
        try send(
          SwiftBuildOperationPresenter.encodeProgressUpdated(
            statusMessage: "Bazel executed \(count) actions",
            percentComplete: 100,
            showInLog: true
          ),
          channel: channel,
          outputs: outputs
        )
      case .targetCompleted(let label, let succeeded):
        if !succeeded {
          try send(
            SwiftBuildOperationPresenter.encodeDiagnostic(
              SwiftBuildPresentedDiagnostic(
                kind: .error,
                location: .unknown,
                message: "Bazel target failed: \(label)"
              )
            ),
            channel: channel,
            outputs: outputs
          )
        }
      case .finished:
        // The router, not BEP projection, owns the single terminal lifecycle message.
        break
      }
    }
  }

  private func emitFailure(
    _ failure: BazelOperationFailure,
    operation: OwnedBuildOperation,
    outputs: BuildServiceFrameOutputs
  ) throws {
    try send(
      SwiftBuildOperationPresenter.encodeDiagnostic(
        SwiftBuildPresentedDiagnostic(
          kind: .error,
          location: .unknown,
          message: "Bazel build failed during \(failure.phase.rawValue): \(failure.message)"
        )
      ),
      channel: operation.responseChannel,
      outputs: outputs
    )
  }

  private func emitOperationSuffix(
    _ operation: OwnedBuildOperation,
    status: ProxyTerminalStatus,
    signalled: Bool,
    outputs: BuildServiceFrameOutputs
  ) throws {
    let taskStatus: SwiftBuildPresentedTaskStatus
    let operationStatus: SwiftBuildPresentedOperationStatus
    switch status {
    case .cancelled:
      taskStatus = .cancelled
      operationStatus = .cancelled
    case .failed:
      taskStatus = .failed
      operationStatus = .failed
    case .succeeded:
      taskStatus = .succeeded
      operationStatus = .succeeded
    }
    try send(
      SwiftBuildOperationPresenter.encodeTaskEnded(
        id: operation.presentation.wrapperTaskID,
        stableSignature: operation.presentation.wrapperTaskSignature,
        status: taskStatus,
        signalled: signalled
      ),
      channel: operation.responseChannel,
      outputs: outputs
    )
    for target in operation.plan.targets.reversed() {
      guard let id = operation.presentation.targetIDsByGUID[target.mapping.xcodeTargetGUID] else {
        continue
      }
      try send(
        SwiftBuildOperationPresenter.encodeTargetEnded(id: id),
        channel: operation.responseChannel,
        outputs: outputs
      )
    }
    try send(
      SwiftBuildOperationPresenter.encodeOperationEnded(
        id: operation.protocolID,
        status: operationStatus
      ),
      channel: operation.responseChannel,
      outputs: outputs
    )
  }

  private static func wasSignalled(_ completion: ProcessCompletion?) -> Bool {
    guard let completion else { return false }
    if case .signalled = completion.termination { return true }
    return false
  }

  private func makePresentation(for plan: ResolvedBuildPlan) -> OwnedOperationPresentation {
    let targetIDs = Dictionary(
      uniqueKeysWithValues: plan.targets.enumerated().map {
        ($0.element.mapping.xcodeTargetGUID, $0.offset + 1)
      }
    )
    return OwnedOperationPresentation(
      targetIDsByGUID: targetIDs,
      wrapperTaskID: 1,
      wrapperTaskSignature: "rules_xcodeproj.bazel.operation.v1:\(plan.operationID)",
      nextTaskID: 2
    )
  }

  private func allocateOperationDirectoryIdentity() -> String {
    condition.lock()
    let sequence = nextOperationSequence
    nextOperationSequence += 1
    condition.unlock()
    return "xcode-\(operationDirectoryNamespace)-\(sequence)"
  }

  private func asyncTaskDidFinish() {
    condition.lock()
    precondition(activeAsyncTaskCount > 0)
    activeAsyncTaskCount -= 1
    condition.broadcast()
    condition.unlock()
  }

  private func eventDidFinish(operationID: Int) {
    condition.lock()
    if var operation = operations[operationID], operation.inFlightEventCount > 0 {
      operation.inFlightEventCount -= 1
      operations[operationID] = operation
    }
    condition.broadcast()
    condition.unlock()
  }

  private func isPrivateChannel(_ channel: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return everPrivateChannels.contains(channel)
  }

  private func isUnavailablePublicClientChannel(_ channel: UInt64) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return isUnavailablePublicClientChannelLocked(channel)
  }

  private func isUnavailablePublicClientChannelLocked(_ channel: UInt64) -> Bool {
    everEventChannels.contains(channel)
      || resolvingBuildsByRequestChannel[channel] != nil
      || resolvingBuildsByRequestChannel.values.contains { $0.eventChannel == channel }
      || nativePendingBuildsByRequestChannel[channel] != nil
      || nativePendingBuildsByRequestChannel.values.contains { $0.eventChannel == channel }
      || nativeBuildIDsByEventChannel[channel] != nil
      || deleteSessionsByRequestChannel[channel] != nil
      || operations.values.contains { $0.responseChannel == channel }
  }

  private func allocateProtocolOperationID() -> Int? {
    condition.lock()
    defer { condition.unlock() }
    let candidate = nextProtocolOperationID
    guard candidate < 0, candidate != Int.min else { return nil }
    nextProtocolOperationID = candidate == Int.min + 1 ? Int.min : candidate - 1
    return candidate
  }

  private func validateAndReserveCreateChannels(
    requestChannel: UInt64,
    eventChannel: UInt64
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard requestChannel != 0, eventChannel != 0, requestChannel != eventChannel,
      !everPrivateChannels.contains(requestChannel),
      !everPrivateChannels.contains(eventChannel),
      !isUnavailablePublicClientChannelLocked(requestChannel),
      !isUnavailablePublicClientChannelLocked(eventChannel),
      !observedChannels.contains(eventChannel),
      nativePendingBuildsByRequestChannel[requestChannel] == nil
    else {
      return false
    }
    observedChannels.formUnion([requestChannel, eventChannel])
    everEventChannels.insert(eventChannel)
    return true
  }

  private func registerNativePendingBuild(
    requestChannel: UInt64,
    request: CreateBuildRequest,
    operationClass: BuildOperationClass
  ) {
    condition.lock()
    nativePendingBuildsByRequestChannel[requestChannel] = NativePendingBuild(
      eventChannel: request.responseChannel,
      operationClass: operationClass,
      sessionHandle: request.sessionHandle
    )
    condition.unlock()
  }

  private func hasProxyConflict(
    sessionHandle: String,
    operationClass: BuildOperationClass
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return operations.values.contains {
      $0.sessionHandle == sessionHandle && $0.operationClass == operationClass
        && $0.state.holdsBuildClassCapacity
    }
  }

  private func hasResolvingConflict(
    sessionHandle: String,
    operationClass: BuildOperationClass,
    excludingRequestChannel: UInt64?
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return resolvingBuildsByRequestChannel.contains {
      $0.key != excludingRequestChannel && $0.value.sessionHandle == sessionHandle
        && $0.value.operationClass == operationClass
    }
  }

  private func hasNativeConflict(
    sessionHandle: String,
    operationClass: BuildOperationClass
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return nativePendingBuildsByRequestChannel.values.contains {
      $0.sessionHandle == sessionHandle && $0.operationClass == operationClass
    }
      || nativeActiveBuilds.values.contains {
        $0.sessionHandle == sessionHandle && $0.operationClass == operationClass
      }
  }

  private static func operationClass(for request: CreateBuildRequest) -> BuildOperationClass {
    if request.onlyCreateBuildDescription { return .buildDescription }
    return request.request.parameters.action == "indexbuild" ? .index : .normal
  }

  private func allocateAuxiliaryChannel() -> UInt64? {
    condition.lock()
    defer { condition.unlock() }
    guard var candidate = nextAuxiliaryChannel else { return nil }
    while candidate >= Self.auxiliaryChannelLowerBound {
      if !observedChannels.contains(candidate), activeQueries[candidate] == nil,
        !drainingResponseChannels.contains(candidate)
      {
        observedChannels.insert(candidate)
        everPrivateChannels.insert(candidate)
        nextAuxiliaryChannel =
          candidate == Self.auxiliaryChannelLowerBound
          ? nil : candidate - 1
        return candidate
      }
      if candidate == Self.auxiliaryChannelLowerBound {
        nextAuxiliaryChannel = nil
        return nil
      }
      candidate -= 1
    }
    nextAuxiliaryChannel = nil
    return nil
  }

  private func settingsKeys() -> [String] {
    Array(
      Set(ResolvedBuildPlanSettingRole.orderedKeys)
        .union(configuration.verifiedManifest.manifest.invocation.environmentKeys)
    ).sorted()
  }

  private func clearSessionLocked(_ sessionHandle: String) {
    nativePendingBuildsByRequestChannel = nativePendingBuildsByRequestChannel.filter {
      $0.value.sessionHandle != sessionHandle
    }
    let nativeIDs = nativeActiveBuilds.filter { $0.value.sessionHandle == sessionHandle }.map(\.key)
    for id in nativeIDs {
      if let eventChannel = nativeActiveBuilds[id]?.eventChannel {
        nativeBuildIDsByEventChannel.removeValue(forKey: eventChannel)
      }
      nativeActiveBuilds.removeValue(forKey: id)
    }
    operations = operations.filter { $0.value.sessionHandle != sessionHandle }
    deletingSessions.remove(sessionHandle)
  }

  private func takeReadyDeleteRequestsLocked(
    for sessionHandle: String
  ) -> [HeldDeleteSessionRequest] {
    let hasActive =
      operations.values.contains {
        $0.sessionHandle == sessionHandle && $0.state != .terminal
      }
      || resolvingBuildsByRequestChannel.values.contains {
        $0.sessionHandle == sessionHandle
      }
    guard !hasActive else { return [] }
    let ready = heldDeleteRequests.filter { $0.sessionHandle == sessionHandle }
    heldDeleteRequests.removeAll { $0.sessionHandle == sessionHandle }
    return ready
  }

  private func forwardDeleteRequests(_ requests: [HeldDeleteSessionRequest]) throws {
    for request in requests {
      try request.outputs.sendToNative(request.frame)
    }
  }

  private func sendError(
    _ message: String,
    channel: UInt64,
    outputs: BuildServiceFrameOutputs
  ) throws {
    try send(
      SwiftBuildOperationPresenter.encodeError(message),
      channel: channel,
      outputs: outputs
    )
  }

  private func sendPreStartCancellation(_ operation: OwnedBuildOperation) throws {
    // Once BuildCreated has been committed, even ErrorResponse is unsafe until the pinned
    // client's create continuation runs: it changes the operation state before that continuation
    // asserts `.requested` and installs the ID. START or CANCEL is the only causal readiness ack.
    guard operation.clientReadyForLifecycleEvents else { return }
    try send(
      SwiftBuildOperationPresenter.encodeOperationEnded(
        id: operation.protocolID,
        status: .cancelled
      ),
      channel: operation.responseChannel,
      outputs: operation.outputs
    )
  }

  private func sendRegistrationError(
    _ message: String,
    requestChannel: UInt64,
    eventChannel: UInt64,
    outputs: BuildServiceFrameOutputs
  ) throws {
    try sendError(message, channel: eventChannel, outputs: outputs)
    try sendError(message, channel: requestChannel, outputs: outputs)
  }

  private func send(
    _ payload: [UInt8],
    channel: UInt64,
    outputs: BuildServiceFrameOutputs
  ) throws {
    try outputs.sendToXcode(BuildServiceRawFrame(channel: channel, payload: payload))
  }
}
