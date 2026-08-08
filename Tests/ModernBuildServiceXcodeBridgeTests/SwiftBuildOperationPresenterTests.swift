import Foundation
import SWBProtocol
import SWBUtil
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class SwiftBuildOperationPresenterTests: XCTestCase {
  private let operationID = -1
  private let stableSignature = "rules_xcodeproj.bazel.v1://app:App"

  func testTypedRequestDecodersPreserveSessionIDAndOperationID() throws {
    let start = BuildStartRequest(sessionHandle: "SESSION-1", id: operationID)
    let cancel = BuildCancelRequest(sessionHandle: "SESSION-1", id: operationID)
    let delete = DeleteSessionRequest(sessionHandle: "SESSION-1")

    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeBuildStart(SwiftBuildProtocolCodec.encode(start)),
      start
    )
    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeBuildCancel(SwiftBuildProtocolCodec.encode(cancel)),
      cancel
    )
    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeDeleteSession(SwiftBuildProtocolCodec.encode(delete)),
      delete
    )
  }

  func testTypedObservationDecodersPreserveNativeResponses() throws {
    let created = BuildCreated(id: 17)
    let error = ErrorResponse("native failure")
    let ended = BuildOperationEnded(id: 17, status: .failed)

    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeBuildCreated(SwiftBuildProtocolCodec.encode(created)),
      created
    )
    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeErrorResponse(SwiftBuildProtocolCodec.encode(error)),
      error
    )
    XCTAssertEqual(
      try SwiftBuildProtocolCodec.decodeBuildOperationEnded(
        SwiftBuildProtocolCodec.encode(ended)
      ),
      ended
    )
  }

  func testTypedDecoderRejectsWrongMessageShape() {
    let payload = SwiftBuildProtocolCodec.encode(BoolResponse(true))

    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeBuildStart(payload)) {
      XCTAssertEqual(
        $0 as? SwiftBuildProtocolCodecError,
        .unexpectedMessage(expected: BuildStartRequest.name, actual: BoolResponse.name)
      )
    }
    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeBuildCancel(payload))
    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeDeleteSession(payload))
    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeBuildCreated(payload))
    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeErrorResponse(payload))
    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeBuildOperationEnded(payload))
  }

  func testBuildCreatedSupportsNegativeAndMinimumPlusOneIDs() throws {
    for id in [-1, Int.min + 1] {
      let payload = SwiftBuildOperationPresenter.encodeBuildCreated(id: id)
      XCTAssertEqual(try SwiftBuildProtocolCodec.decodeBuildCreated(payload).id, id)
    }
  }

  func testVoidResponseUsesPinnedPingWireShape() throws {
    let payload = SwiftBuildOperationPresenter.encodeVoidResponse()
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)

    XCTAssertEqual(type(of: message.message).name, "PING")
    XCTAssertNotNil(message.message as? VoidResponse)
    XCTAssertEqual(SwiftBuildProtocolCodec.encode(message.message), payload)
  }

  func testPresenterConstructsPreparationOperationAndPathMap() throws {
    XCTAssertNotNil(
      try decode(
        SwiftBuildOperationPresenter.encodePreparationCompleted(),
        as: BuildOperationPreparationCompleted.self
      )
    )
    XCTAssertEqual(
      try decode(
        SwiftBuildOperationPresenter.encodeOperationStarted(id: operationID),
        as: BuildOperationStarted.self
      ).id,
      operationID
    )

    let pathMap = try decode(
      SwiftBuildOperationPresenter.encodePathMap(
        copied: ["/workspace/source": "/derived/copied"],
        generated: ["/workspace/generated": "/derived/generated"]
      ),
      as: BuildOperationReportPathMap.self
    )
    XCTAssertEqual(pathMap.copiedPathMap, ["/workspace/source": "/derived/copied"])
    XCTAssertEqual(
      pathMap.generatedFilesPathMap,
      ["/workspace/generated": "/derived/generated"]
    )
  }

  func testPresenterConstructsEveryTargetType() throws {
    for targetType in SwiftBuildPresentedTargetType.allCases {
      let target = try decode(
        SwiftBuildOperationPresenter.encodeTargetStarted(makeTarget(type: targetType)),
        as: BuildOperationTargetStarted.self
      )

      XCTAssertEqual(target.id, 1)
      XCTAssertEqual(target.guid, "TARGET-A")
      XCTAssertEqual(target.info.name, "App")
      XCTAssertEqual(target.info.typeName, expectedTargetType(targetType))
      XCTAssertEqual(target.info.projectInfo.name, "AppProject")
      XCTAssertEqual(target.info.projectInfo.path, "/workspace/App.xcodeproj")
      XCTAssertFalse(target.info.projectInfo.isPackage)
      XCTAssertTrue(target.info.projectInfo.isNameUniqueInWorkspace)
      XCTAssertEqual(target.info.configurationName, "Debug")
      XCTAssertFalse(target.info.configurationIsDefault)
      XCTAssertEqual(target.info.sdkroot, "iphonesimulator")
    }
  }

  func testPresenterConstructsTaskAndStableSignature() throws {
    let task = try decode(
      SwiftBuildOperationPresenter.encodeTaskStarted(makeTask()),
      as: BuildOperationTaskStarted.self
    )
    let signature = SwiftBuildOperationPresenter.taskSignature(stableSignature)

    XCTAssertEqual(task.id, 1)
    XCTAssertEqual(task.targetID, 1)
    XCTAssertNil(task.parentID)
    XCTAssertEqual(task.info.taskName, "Bazel")
    XCTAssertEqual(task.info.signature, signature.rawValue)
    XCTAssertEqual(task.info.ruleInfo, "BazelBuild //app:App")
    XCTAssertEqual(task.info.executionDescription, "Build with Bazel")
    XCTAssertEqual(task.info.commandLineDisplayString, "bazel build //app:App")
    XCTAssertEqual(task.info.interestingPath, Path("/workspace/app/BUILD"))
    XCTAssertEqual(task.info.serializedDiagnosticsPaths, [Path("/derived/app.dia")])
  }

  func testPresenterUsesSubtaskSignatureForNestedTaskLifecycle() throws {
    let signature = "rules_xcodeproj.bazel.action.v1://app:App|App.app|debug"
    let task = SwiftBuildPresentedTask(
      commandLineDisplayString: nil,
      executionDescription: "SwiftCompile",
      id: 2,
      interestingPath: nil,
      parentID: 1,
      ruleInfo: "BazelAction //app:App",
      serializedDiagnosticsPaths: [],
      stableSignature: signature,
      targetID: 1,
      taskName: "SwiftCompile"
    )

    let started = try decode(
      SwiftBuildOperationPresenter.encodeTaskStarted(task),
      as: BuildOperationTaskStarted.self
    )
    let ended = try decode(
      SwiftBuildOperationPresenter.encodeTaskEnded(
        id: task.id,
        stableSignature: signature,
        status: .succeeded,
        signalled: false,
        parentID: task.parentID
      ),
      as: BuildOperationTaskEnded.self
    )
    let expected = BuildOperationTaskSignature.subtaskSignature(
      ByteString(encodingAsUTF8: signature)
    )

    XCTAssertEqual(started.parentID, 1)
    XCTAssertEqual(started.info.signature, expected.rawValue)
    XCTAssertEqual(ended.signature, expected)
  }

  func testPresenterConstructsProgress() throws {
    let progress = try decode(
      SwiftBuildOperationPresenter.encodeProgressUpdated(
        targetName: "App",
        statusMessage: "Analyzing Bazel build",
        percentComplete: -1,
        showInLog: false
      ),
      as: BuildOperationProgressUpdated.self
    )

    XCTAssertEqual(progress.targetName, "App")
    XCTAssertEqual(progress.statusMessage, "Analyzing Bazel build")
    XCTAssertEqual(progress.percentComplete, -1)
    XCTAssertFalse(progress.showInLog)
  }

  func testConsoleInitializerIntentionallyDropsTaskSignatureAtPin() throws {
    let console = try decode(
      SwiftBuildOperationPresenter.encodeConsoleOutput(
        data: Array("synthetic output\n".utf8),
        taskID: 1,
        stableSignature: stableSignature
      ),
      as: BuildOperationConsoleOutputEmitted.self
    )

    XCTAssertEqual(console.data, Array("synthetic output\n".utf8))
    XCTAssertEqual(console.taskID, 1)
    XCTAssertNil(console.taskSignature)
    XCTAssertNil(console.targetID)
  }

  func testPresenterConstructsEveryDiagnosticKindAndSortsTraits() throws {
    for kind in SwiftBuildPresentedDiagnosticKind.allCases {
      let diagnostic = try decode(
        SwiftBuildOperationPresenter.encodeDiagnostic(
          SwiftBuildPresentedDiagnostic(
            context: .globalTask(taskID: 1, stableSignature: stableSignature),
            kind: kind,
            location: .path("/workspace/app/main.swift", line: 7, column: 3),
            message: "synthetic diagnostic",
            optionName: "synthetic-option",
            traits: ["zeta", "alpha"]
          )
        ),
        as: BuildOperationDiagnosticEmitted.self
      )

      XCTAssertEqual(diagnostic.kind, expectedDiagnosticKind(kind))
      XCTAssertEqual(
        diagnostic.location,
        .path(Path("/workspace/app/main.swift"), line: 7, column: 3)
      )
      XCTAssertEqual(
        diagnostic.locationContext,
        .globalTask(
          taskID: 1,
          taskSignature: SwiftBuildOperationPresenter.taskSignature(stableSignature)
        )
      )
      XCTAssertEqual(diagnostic.message, "synthetic diagnostic")
      XCTAssertEqual(diagnostic.component, .default)
      XCTAssertEqual(diagnostic.optionName, "synthetic-option")
      XCTAssertFalse(diagnostic.appendToOutputStream)
      XCTAssertEqual(diagnostic.traits, ["alpha", "zeta"])
      XCTAssertTrue(diagnostic.sourceRanges.isEmpty)
      XCTAssertTrue(diagnostic.fixIts.isEmpty)
      XCTAssertTrue(diagnostic.childDiagnostics.isEmpty)
    }
  }

  func testPresenterConstructsEveryDiagnosticContext() throws {
    let contexts: [SwiftBuildPresentedDiagnosticContext] = [
      .global,
      .target(targetID: 1),
      .globalTask(taskID: 2, stableSignature: stableSignature),
      .task(taskID: 2, stableSignature: stableSignature, targetID: 1),
    ]

    for context in contexts {
      let diagnostic = try decode(
        SwiftBuildOperationPresenter.encodeDiagnostic(
          SwiftBuildPresentedDiagnostic(
            context: context,
            kind: .note,
            location: .unknown,
            message: "context"
          )
        ),
        as: BuildOperationDiagnosticEmitted.self
      )
      XCTAssertEqual(diagnostic.location, .unknown)
      XCTAssertEqual(diagnostic.locationContext, expectedContext(context))
    }
  }

  func testPresenterConstructsEveryTaskTerminalStatus() throws {
    for status in SwiftBuildPresentedTaskStatus.allCases {
      let ended = try decode(
        SwiftBuildOperationPresenter.encodeTaskEnded(
          id: 1,
          stableSignature: stableSignature,
          status: status,
          signalled: status == .cancelled
        ),
        as: BuildOperationTaskEnded.self
      )

      XCTAssertEqual(ended.id, 1)
      XCTAssertEqual(ended.signature, SwiftBuildOperationPresenter.taskSignature(stableSignature))
      XCTAssertEqual(ended.status, expectedTaskStatus(status))
      XCTAssertEqual(ended.signalled, status == .cancelled)
      XCTAssertNil(ended.metrics)
    }
  }

  func testPresenterConstructsTargetAndEveryOperationTerminalStatus() throws {
    XCTAssertEqual(
      try decode(
        SwiftBuildOperationPresenter.encodeTargetEnded(id: 1),
        as: BuildOperationTargetEnded.self
      ).id,
      1
    )

    for status in SwiftBuildPresentedOperationStatus.allCases {
      let endedPayload = SwiftBuildOperationPresenter.encodeOperationEnded(
        id: operationID,
        status: status
      )
      let ended = try SwiftBuildProtocolCodec.decodeBuildOperationEnded(endedPayload)

      XCTAssertEqual(ended.id, operationID)
      XCTAssertEqual(ended.status, expectedOperationStatus(status))
      XCTAssertNil(ended.metrics)
    }
  }

  func testSuccessFailureAndCancelTerminalStreamsHaveNativeShape() throws {
    let prefix = [
      SwiftBuildOperationPresenter.encodePreparationCompleted(),
      SwiftBuildOperationPresenter.encodeOperationStarted(id: operationID),
      SwiftBuildOperationPresenter.encodePathMap(copied: [:], generated: [:]),
      SwiftBuildOperationPresenter.encodeTargetStarted(makeTarget(type: .standard)),
      SwiftBuildOperationPresenter.encodeTaskStarted(makeTask()),
    ]
    XCTAssertEqual(
      try prefix.map(messageName),
      [
        BuildOperationPreparationCompleted.name,
        BuildOperationStarted.name,
        BuildOperationReportPathMap.name,
        BuildOperationTargetStarted.name,
        BuildOperationTaskStarted.name,
      ]
    )

    for (taskStatus, operationStatus) in [
      (SwiftBuildPresentedTaskStatus.succeeded, SwiftBuildPresentedOperationStatus.succeeded),
      (.failed, .failed),
      (.cancelled, .cancelled),
    ] {
      let suffix = [
        SwiftBuildOperationPresenter.encodeTaskEnded(
          id: 1,
          stableSignature: stableSignature,
          status: taskStatus,
          signalled: taskStatus == .cancelled
        ),
        SwiftBuildOperationPresenter.encodeTargetEnded(id: 1),
        SwiftBuildOperationPresenter.encodeOperationEnded(
          id: operationID,
          status: operationStatus
        ),
      ]
      XCTAssertEqual(
        try suffix.map(messageName),
        [
          BuildOperationTaskEnded.name,
          BuildOperationTargetEnded.name,
          BuildOperationEnded.name,
        ]
      )
    }
  }

  private func decode<T: Message>(_ payload: [UInt8], as type: T.Type) throws -> T {
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)
    return try XCTUnwrap(message.message as? T)
  }

  private func messageName(_ payload: [UInt8]) throws -> String {
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)
    return type(of: message.message).name
  }

  private func makeTarget(
    type: SwiftBuildPresentedTargetType
  ) -> SwiftBuildPresentedTarget {
    SwiftBuildPresentedTarget(
      configurationIsDefault: false,
      configurationName: "Debug",
      guid: "TARGET-A",
      id: 1,
      name: "App",
      project: SwiftBuildPresentedProject(
        isNameUniqueInWorkspace: true,
        isPackage: false,
        name: "AppProject",
        path: "/workspace/App.xcodeproj"
      ),
      sdkCanonicalName: "iphonesimulator",
      type: type
    )
  }

  private func makeTask() -> SwiftBuildPresentedTask {
    SwiftBuildPresentedTask(
      commandLineDisplayString: "bazel build //app:App",
      executionDescription: "Build with Bazel",
      id: 1,
      interestingPath: "/workspace/app/BUILD",
      parentID: nil,
      ruleInfo: "BazelBuild //app:App",
      serializedDiagnosticsPaths: ["/derived/app.dia"],
      stableSignature: stableSignature,
      targetID: 1,
      taskName: "Bazel"
    )
  }

  private func expectedTargetType(
    _ type: SwiftBuildPresentedTargetType
  ) -> BuildOperationTargetType {
    switch type {
    case .aggregate: .aggregate
    case .external: .external
    case .packageProduct: .packageProduct
    case .standard: .standard
    }
  }

  private func expectedDiagnosticKind(
    _ kind: SwiftBuildPresentedDiagnosticKind
  ) -> BuildOperationDiagnosticEmitted.Kind {
    switch kind {
    case .error: .error
    case .note: .note
    case .remark: .remark
    case .warning: .warning
    }
  }

  private func expectedContext(
    _ context: SwiftBuildPresentedDiagnosticContext
  ) -> BuildOperationDiagnosticEmitted.LocationContext {
    switch context {
    case .global:
      .global
    case .globalTask(let taskID, let signature):
      .globalTask(
        taskID: taskID,
        taskSignature: SwiftBuildOperationPresenter.taskSignature(signature)
      )
    case .target(let targetID):
      .target(targetID: targetID)
    case .task(let taskID, let signature, let targetID):
      .task(
        taskID: taskID,
        taskSignature: SwiftBuildOperationPresenter.taskSignature(signature),
        targetID: targetID
      )
    }
  }

  private func expectedTaskStatus(
    _ status: SwiftBuildPresentedTaskStatus
  ) -> BuildOperationTaskEnded.Status {
    switch status {
    case .cancelled: .cancelled
    case .failed: .failed
    case .succeeded: .succeeded
    }
  }

  private func expectedOperationStatus(
    _ status: SwiftBuildPresentedOperationStatus
  ) -> BuildOperationEnded.Status {
    switch status {
    case .cancelled: .cancelled
    case .failed: .failed
    case .succeeded: .succeeded
    }
  }
}
