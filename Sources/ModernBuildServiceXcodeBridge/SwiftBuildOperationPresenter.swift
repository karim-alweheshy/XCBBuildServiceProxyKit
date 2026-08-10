import Foundation
import SWBProtocol
import SWBUtil

enum SwiftBuildPresentedOperationStatus: CaseIterable, Equatable, Sendable {
  case cancelled
  case failed
  case succeeded
}

enum SwiftBuildPresentedTaskStatus: CaseIterable, Equatable, Sendable {
  case cancelled
  case failed
  case succeeded
}

enum SwiftBuildPresentedTargetType: CaseIterable, Equatable, Sendable {
  case aggregate
  case external
  case packageProduct
  case standard
}

struct SwiftBuildPresentedProject: Equatable, Sendable {
  let isNameUniqueInWorkspace: Bool
  let isPackage: Bool
  let name: String
  let path: String
}

struct SwiftBuildPresentedTarget: Equatable, Sendable {
  let configurationIsDefault: Bool
  let configurationName: String
  let guid: String
  let id: Int
  let name: String
  let project: SwiftBuildPresentedProject
  let sdkCanonicalName: String?
  let type: SwiftBuildPresentedTargetType
}

struct SwiftBuildPresentedTask: Equatable, Sendable {
  let commandLineDisplayString: String?
  let executionDescription: String
  let id: Int
  let interestingPath: String?
  let parentID: Int?
  let ruleInfo: String
  let serializedDiagnosticsPaths: [String]
  let stableSignature: String
  let targetID: Int?
  let taskName: String
}

enum SwiftBuildPresentedDiagnosticKind: CaseIterable, Equatable, Sendable {
  case error
  case note
  case remark
  case warning
}

enum SwiftBuildPresentedDiagnosticLocation: Equatable, Sendable {
  case path(String, line: Int?, column: Int?)
  case unknown
}

enum SwiftBuildPresentedDiagnosticContext: Equatable, Sendable {
  case global
  case globalTask(taskID: Int, stableSignature: String)
  case target(targetID: Int)
  case task(taskID: Int, stableSignature: String, targetID: Int)
}

struct SwiftBuildPresentedDiagnostic: Equatable, Sendable {
  let appendToOutputStream: Bool
  let context: SwiftBuildPresentedDiagnosticContext
  let kind: SwiftBuildPresentedDiagnosticKind
  let location: SwiftBuildPresentedDiagnosticLocation
  let message: String
  let optionName: String?
  let traits: Set<String>

  init(
    appendToOutputStream: Bool = false,
    context: SwiftBuildPresentedDiagnosticContext = .global,
    kind: SwiftBuildPresentedDiagnosticKind,
    location: SwiftBuildPresentedDiagnosticLocation,
    message: String,
    optionName: String? = nil,
    traits: Set<String> = []
  ) {
    self.appendToOutputStream = appendToOutputStream
    self.context = context
    self.kind = kind
    self.location = location
    self.message = message
    self.optionName = optionName
    self.traits = traits
  }
}

/// Constructs the public Swift Build messages used by an independently owned build operation.
///
/// Inputs deliberately contain no transport, Bazel, or Swift Build service-internal types. The
/// caller supplies already validated presentation facts and chooses the outer protocol channel.
enum SwiftBuildOperationPresenter {
  static func encodeError(_ message: String) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(ErrorResponse(message))
  }

  static func encodeBuildCreated(id: Int) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(BuildCreated(id: id))
  }

  /// `VoidResponse` is a public alias of `PingRequest` at the pinned Swift Build revision and has
  /// the wire name `PING`.
  static func encodeVoidResponse() -> [UInt8] {
    SwiftBuildProtocolCodec.encode(VoidResponse())
  }

  static func encodePreparationCompleted() -> [UInt8] {
    SwiftBuildProtocolCodec.encode(BuildOperationPreparationCompleted())
  }

  static func encodeOperationStarted(id: Int) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(BuildOperationStarted(id: id))
  }

  static func encodePathMap(
    copied: [String: String],
    generated: [String: String]
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationReportPathMap(
        copiedPathMap: copied,
        generatedFilesPathMap: generated
      )
    )
  }

  static func encodeTargetStarted(_ target: SwiftBuildPresentedTarget) -> [UInt8] {
    let project = BuildOperationProjectInfo(
      name: target.project.name,
      path: target.project.path,
      isPackage: target.project.isPackage,
      isNameUniqueInWorkspace: target.project.isNameUniqueInWorkspace
    )
    let info = BuildOperationTargetInfo(
      name: target.name,
      type: target.type.protocolValue,
      projectInfo: project,
      configurationName: target.configurationName,
      configurationIsDefault: target.configurationIsDefault,
      sdkCanonicalName: target.sdkCanonicalName
    )
    return SwiftBuildProtocolCodec.encode(
      BuildOperationTargetStarted(id: target.id, guid: target.guid, info: info)
    )
  }

  static func encodeTaskStarted(_ task: SwiftBuildPresentedTask) -> [UInt8] {
    let signature = taskSignature(task.stableSignature, parentID: task.parentID)
    let info = BuildOperationTaskInfo(
      taskName: task.taskName,
      signature: signature,
      ruleInfo: task.ruleInfo,
      executionDescription: task.executionDescription,
      commandLineDisplayString: task.commandLineDisplayString,
      interestingPath: task.interestingPath.map(Path.init),
      serializedDiagnosticsPaths: task.serializedDiagnosticsPaths.map(Path.init)
    )
    return SwiftBuildProtocolCodec.encode(
      BuildOperationTaskStarted(
        id: task.id,
        targetID: task.targetID,
        parentID: task.parentID,
        info: info
      )
    )
  }

  static func encodeProgressUpdated(
    targetName: String? = nil,
    statusMessage: String,
    percentComplete: Double,
    showInLog: Bool
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationProgressUpdated(
        targetName: targetName,
        statusMessage: statusMessage,
        percentComplete: percentComplete,
        showInLog: showInLog
      )
    )
  }

  static func encodeConsoleOutput(
    data: [UInt8]
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationConsoleOutputEmitted(data: data)
    )
  }

  static func encodeConsoleOutput(
    data: [UInt8],
    taskID: Int,
    stableSignature: String
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationConsoleOutputEmitted(
        data: data,
        taskID: taskID,
        taskSignature: taskSignature(stableSignature)
      )
    )
  }

  static func encodeDiagnostic(_ diagnostic: SwiftBuildPresentedDiagnostic) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationDiagnosticEmitted(
        kind: diagnostic.kind.protocolValue,
        location: diagnostic.location.protocolValue,
        message: diagnostic.message,
        locationContext: diagnostic.context.protocolValue,
        component: .default,
        optionName: diagnostic.optionName,
        appendToOutputStream: diagnostic.appendToOutputStream,
        sourceRanges: [],
        fixIts: [],
        traits: diagnostic.traits,
        attachments: [:],
        childDiagnostics: []
      )
    )
  }

  static func encodeTaskEnded(
    id: Int,
    stableSignature: String,
    status: SwiftBuildPresentedTaskStatus,
    signalled: Bool,
    parentID: Int? = nil
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationTaskEnded(
        id: id,
        signature: taskSignature(stableSignature, parentID: parentID),
        status: status.protocolValue,
        signalled: signalled,
        metrics: nil
      )
    )
  }

  static func encodeTargetEnded(id: Int) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(BuildOperationTargetEnded(id: id))
  }

  static func encodeOperationEnded(
    id: Int,
    status: SwiftBuildPresentedOperationStatus
  ) -> [UInt8] {
    SwiftBuildProtocolCodec.encode(
      BuildOperationEnded(id: id, status: status.protocolValue)
    )
  }

  static func taskSignature(
    _ stableSignature: String,
    parentID: Int? = nil
  ) -> BuildOperationTaskSignature {
    let bytes = ByteString(encodingAsUTF8: stableSignature)
    return parentID == nil ? .taskIdentifier(bytes) : .subtaskSignature(bytes)
  }
}

extension SwiftBuildPresentedOperationStatus {
  fileprivate var protocolValue: BuildOperationEnded.Status {
    switch self {
    case .cancelled: .cancelled
    case .failed: .failed
    case .succeeded: .succeeded
    }
  }
}

extension SwiftBuildPresentedTaskStatus {
  fileprivate var protocolValue: BuildOperationTaskEnded.Status {
    switch self {
    case .cancelled: .cancelled
    case .failed: .failed
    case .succeeded: .succeeded
    }
  }
}

extension SwiftBuildPresentedTargetType {
  fileprivate var protocolValue: BuildOperationTargetType {
    switch self {
    case .aggregate: .aggregate
    case .external: .external
    case .packageProduct: .packageProduct
    case .standard: .standard
    }
  }
}

extension SwiftBuildPresentedDiagnosticKind {
  fileprivate var protocolValue: BuildOperationDiagnosticEmitted.Kind {
    switch self {
    case .error: .error
    case .note: .note
    case .remark: .remark
    case .warning: .warning
    }
  }
}

extension SwiftBuildPresentedDiagnosticLocation {
  fileprivate var protocolValue: BuildOperationDiagnosticEmitted.Location {
    switch self {
    case .path(let path, let line, let column):
      .path(Path(path), line: line, column: column)
    case .unknown:
      .unknown
    }
  }
}

extension SwiftBuildPresentedDiagnosticContext {
  fileprivate var protocolValue: BuildOperationDiagnosticEmitted.LocationContext {
    switch self {
    case .global:
      .global
    case .globalTask(let taskID, let stableSignature):
      .globalTask(
        taskID: taskID,
        taskSignature: SwiftBuildOperationPresenter.taskSignature(stableSignature)
      )
    case .target(let targetID):
      .target(targetID: targetID)
    case .task(let taskID, let stableSignature, let targetID):
      .task(
        taskID: taskID,
        taskSignature: SwiftBuildOperationPresenter.taskSignature(stableSignature),
        targetID: targetID
      )
    }
  }
}
