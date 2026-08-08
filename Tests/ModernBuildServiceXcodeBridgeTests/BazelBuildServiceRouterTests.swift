import BazelProxyCore
import Darwin
import Foundation
import ModernBuildServiceProxyCore
import SWBProtocol
import SWBUtil
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class BazelBuildServiceRouterTests: XCTestCase {
  func testPresentsCacheAndWorkerActionDetailsWithCommands() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithDetailedActions)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let create = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 201
    )

    XCTAssertTrue(try harness.sendClient(create, channel: 101))
    XCTAssertEqual(try harness.createdID(on: 101), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: create.sessionHandle, id: -1),
        channel: 102
      )
    )
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))

    let tasks = harness.xcodeFrames(on: 201)
      .filter { $0.messageName == BuildOperationTaskStarted.name }
      .compactMap { try? harness.decode($0, as: BuildOperationTaskStarted.self) }
    let remote = try XCTUnwrap(tasks.first { $0.id == 2 })
    XCTAssertEqual(remote.info.taskName, "Compile Swift module App")
    XCTAssertEqual(
      remote.info.executionDescription,
      "Compile Swift module App — Remote cache hit"
    )
    XCTAssertEqual(remote.info.commandLineDisplayString, "actual-swiftc -c Input.swift")

    let worker = try XCTUnwrap(tasks.first { $0.id == 3 })
    XCTAssertEqual(worker.info.taskName, "Link App")
    XCTAssertEqual(worker.info.executionDescription, "Link App — Executed with worker")
    XCTAssertEqual(worker.info.commandLineDisplayString, "actual-clang -o App")
  }

  func testMappedBuildOwnsCreateStartEventsAndTerminalExactlyOnce() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithEvents)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let create = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 201
    )

    XCTAssertTrue(try harness.sendClient(create, channel: 101))
    XCTAssertEqual(executor.executionCount, 0)
    XCTAssertEqual(try harness.createdID(on: 101), -1)
    XCTAssertEqual(harness.xcodeMessageNames(), [BuildCreated.name])
    XCTAssertFalse(harness.xcodeFrames.contains { $0.channel == 201 })

    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: create.sessionHandle, id: -1),
        channel: 102
      )
    )
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    XCTAssertEqual(executor.executionCount, 1)
    XCTAssertEqual(try harness.messageName(on: 102), VoidResponse.name)

    let eventNames = try harness.xcodeFrames(on: 201).map(harness.messageName)
    XCTAssertEqual(eventNames.first, BuildOperationPreparationCompleted.name)
    XCTAssertEqual(eventNames.dropFirst().first, BuildOperationStarted.name)
    XCTAssertEqual(eventNames.filter { $0 == BuildOperationEnded.name }.count, 1)
    XCTAssertEqual(eventNames.filter { $0 == BuildOperationTargetStarted.name }.count, 1)
    XCTAssertEqual(eventNames.filter { $0 == BuildOperationTargetEnded.name }.count, 1)
    XCTAssertEqual(eventNames.filter { $0 == BuildOperationTaskStarted.name }.count, 3)
    XCTAssertEqual(eventNames.filter { $0 == BuildOperationTaskEnded.name }.count, 3)
    XCTAssertTrue(eventNames.contains(BuildOperationConsoleOutputEmitted.name))
    XCTAssertTrue(eventNames.contains(BuildOperationProgressUpdated.name))
    let actionStarted = try XCTUnwrap(
      harness.xcodeFrames(on: 201)
        .filter { $0.messageName == BuildOperationTaskStarted.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskStarted.self) }
        .first { $0.id == 2 }
    )
    let actionEnded = try XCTUnwrap(
      harness.xcodeFrames(on: 201)
        .filter { $0.messageName == BuildOperationTaskEnded.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskEnded.self) }
        .first { $0.id == 2 }
    )
    XCTAssertNil(actionStarted.parentID)
    XCTAssertEqual(actionStarted.info.taskName, "Compile Swift module App")
    XCTAssertEqual(
      actionStarted.info.executionDescription,
      "Compile Swift module App — Completed (cache status unavailable)"
    )
    XCTAssertEqual(actionStarted.info.ruleInfo, "SwiftCompile //app:App App.app")
    XCTAssertEqual(
      BuildOperationTaskSignature(rawValue: actionStarted.info.signature),
      .taskIdentifier(
        ByteString(encodingAsUTF8: "rules_xcodeproj.bazel.action.v1://app:App|App.app|debug")
      )
    )
    XCTAssertEqual(
      actionEnded.signature,
      BuildOperationTaskSignature(rawValue: actionStarted.info.signature)
    )
    let upToDateStarted = try XCTUnwrap(
      harness.xcodeFrames(on: 201)
        .filter { $0.messageName == BuildOperationTaskStarted.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskStarted.self) }
        .first { $0.id == 3 }
    )
    XCTAssertEqual(upToDateStarted.info.taskName, "Archive App")
    XCTAssertEqual(
      upToDateStarted.info.executionDescription,
      "Archive App — Up to date (cache source unavailable)"
    )
    let progressMessages = harness.xcodeFrames(on: 201)
      .filter { $0.messageName == BuildOperationProgressUpdated.name }
      .compactMap { try? harness.decode($0, as: BuildOperationProgressUpdated.self) }
      .map(\.statusMessage)
    XCTAssertTrue(
      progressMessages.contains(
        "Bazel presented 2 actions: 0 executed, 0 cache hits, 1 completed (cache status unavailable), 1 up-to-date"
      )
    )
    let ended = try SwiftBuildProtocolCodec.decodeBuildOperationEnded(
      try XCTUnwrap(harness.xcodeFrames(on: 201).last).payload
    )
    XCTAssertEqual(ended.id, -1)
    XCTAssertEqual(ended.status, .succeeded)
    let wrapperEnded = try XCTUnwrap(
      harness.xcodeFrames(on: 201)
        .filter { $0.messageName == BuildOperationTaskEnded.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskEnded.self) }
        .first { $0.id == 1 }
    )
    XCTAssertFalse(wrapperEnded.signalled)

    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: create.sessionHandle, id: -1),
        channel: 103
      )
    )
    XCTAssertEqual(try harness.messageName(on: 103), ErrorResponse.name)
    XCTAssertEqual(executor.executionCount, 1)
  }

  func testSeparateRouterProcessesAllocateDistinctOperationDirectories() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithEvents)
    let firstHarness = RouterHarness(fixture: fixture, executor: executor)
    let secondHarness = RouterHarness(fixture: fixture, executor: executor)

    for (index, harness) in [firstHarness, secondHarness].enumerated() {
      let create = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: UInt64(211 + index)
      )
      XCTAssertTrue(try harness.sendClient(create, channel: UInt64(111 + index)))
      XCTAssertEqual(try harness.createdID(on: UInt64(111 + index)), -1)
      XCTAssertTrue(
        try harness.sendClient(
          BuildStartRequest(sessionHandle: create.sessionHandle, id: -1),
          channel: UInt64(121 + index)
        )
      )
      XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    }

    XCTAssertEqual(executor.operationIDs.count, 2)
    XCTAssertNotEqual(executor.operationIDs[0], executor.operationIDs[1])
    XCTAssertTrue(executor.operationIDs.allSatisfy { $0.hasPrefix("xcode-") })
  }

  func testUnrelatedProjectForwardsCreateAndNativeTerminalObservationsRemainTransparent() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 301
    )
    let original = RouterHarness.frame(request, channel: 111)

    XCTAssertTrue(try harness.sendClientFrame(original))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    XCTAssertEqual(harness.nativeFrames.last, original)
    XCTAssertTrue(harness.xcodeFrames.isEmpty)

    let created = RouterHarness.frame(BuildCreated(id: 7), channel: 111)
    XCTAssertTrue(
      harness.router.shouldIntercept(
        direction: .serviceToClient,
        channel: created.channel,
        payloadLength: UInt32(created.payload.count),
        messageName: created.messageName
      ))
    XCTAssertFalse(try harness.sendServiceFrame(created))

    let ended = RouterHarness.frame(
      BuildOperationEnded(id: 7, status: .succeeded),
      channel: 301
    )
    XCTAssertTrue(
      harness.router.shouldIntercept(
        direction: .serviceToClient,
        channel: ended.channel,
        payloadLength: UInt32(ended.payload.count),
        messageName: ended.messageName
      ))
    XCTAssertFalse(try harness.sendServiceFrame(ended))
    XCTAssertTrue(harness.xcodeFrames.isEmpty)
  }

  func testNativeOperationBlocksProxyOperationOfSameClassUntilTerminal() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithEvents)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let nativeRequest = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 401
    )
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    XCTAssertTrue(try harness.sendClient(nativeRequest, channel: 121))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    XCTAssertFalse(try harness.sendService(BuildCreated(id: 9), channel: 121))

    harness.settingsOverrides.removeValue(forKey: "PROJECT_FILE_PATH")
    let blockedRequest = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 402
    )
    XCTAssertFalse(try harness.sendClient(blockedRequest, channel: 122))
    XCTAssertTrue(harness.xcodeFrames(on: 122).isEmpty)
    XCTAssertEqual(executor.executionCount, 0)
    XCTAssertFalse(try harness.sendService(ErrorResponse("native conflict"), channel: 122))

    XCTAssertFalse(
      try harness.sendService(
        BuildOperationEnded(id: 9, status: .succeeded),
        channel: 401
      )
    )
    let acceptedRequest = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 403
    )
    XCTAssertTrue(try harness.sendClient(acceptedRequest, channel: 123))
    XCTAssertEqual(try harness.createdID(on: 123), -1)
  }

  func testProxyOperationRejectsWouldBeNativeOperationOfSameClass() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let proxyRequest = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 501
    )
    XCTAssertTrue(try harness.sendClient(proxyRequest, channel: 131))
    XCTAssertEqual(try harness.createdID(on: 131), -1)

    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let nativeCandidate = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 502
    )
    XCTAssertTrue(try harness.sendClient(nativeCandidate, channel: 132))
    XCTAssertEqual(try harness.messageName(on: 132), ErrorResponse.name)
    XCTAssertEqual(try harness.messageName(on: 502), ErrorResponse.name)
    let errorEntries = harness.entries.filter {
      $0.direction == .xcode && [UInt64(502), UInt64(132)].contains($0.frame.channel)
    }
    XCTAssertEqual(errorEntries.map(\.frame.channel), [502, 132])
    XCTAssertFalse(harness.nativeFrames.contains { $0.channel == 132 })
  }

  func testNormalAndIndexProxyOperationsMayCoexistButSameClassMayNot() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let normal = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 551
    )
    XCTAssertTrue(try harness.sendClient(normal, channel: 135))
    XCTAssertEqual(try harness.createdID(on: 135), -1)

    harness.settingsOverrides["ACTION"] = "indexbuild"
    let index = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      parameters: makeBuildParameters(action: "indexbuild"),
      responseChannel: 552
    )
    XCTAssertTrue(try harness.sendClient(index, channel: 136))
    XCTAssertEqual(try harness.createdID(on: 136), -2)

    let duplicateIndex = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      parameters: makeBuildParameters(action: "indexbuild"),
      responseChannel: 553
    )
    XCTAssertTrue(try harness.sendClient(duplicateIndex, channel: 137))
    XCTAssertEqual(try harness.messageName(on: 137), ErrorResponse.name)
  }

  func testBuildDescriptionOnlyForwardsWithoutSettingsQueryDuringOwnedBuild() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let owned = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 561
    )
    XCTAssertTrue(try harness.sendClient(owned, channel: 138))
    XCTAssertEqual(try harness.createdID(on: 138), -1)
    let nativeCount = harness.nativeFrames.count
    let base = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 562
    )
    let description = CreateBuildRequest(
      sessionHandle: base.sessionHandle,
      responseChannel: base.responseChannel,
      request: base.request,
      onlyCreateBuildDescription: true,
      retainBuildDescription: false
    )

    XCTAssertFalse(try harness.sendClient(description, channel: 139))
    XCTAssertEqual(harness.nativeFrames.count, nativeCount)
  }

  func testNativeErrorOnEventChannelReleasesCombinedConcurrency() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let native = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 571
    )
    XCTAssertTrue(try harness.sendClient(native, channel: 140))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    XCTAssertFalse(try harness.sendService(BuildCreated(id: 12), channel: 140))
    XCTAssertFalse(try harness.sendService(ErrorResponse("aborted"), channel: 571))

    harness.settingsOverrides.removeValue(forKey: "PROJECT_FILE_PATH")
    let mapped = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 572
    )
    XCTAssertTrue(try harness.sendClient(mapped, channel: 144))
    XCTAssertEqual(try harness.createdID(on: 144), -1)
  }

  func testCreateRejectsRequestAndEventChannelCollisionBeforeQuerying() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 145
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 145))
    XCTAssertEqual(try harness.messageName(on: 145), ErrorResponse.name)
    XCTAssertTrue(harness.nativeFrames.isEmpty)
  }

  func testActiveOwnedNativeAndResolvingChannelsRejectClientReuse() throws {
    let fixture = try PlanBuilderFixture()

    do {
      let harness = RouterHarness(fixture: fixture)
      let owned = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 146
      )
      XCTAssertTrue(try harness.sendClient(owned, channel: 147))
      XCTAssertEqual(try harness.createdID(on: 147), -1)
      let reused = RouterHarness.frame(VoidResponse(), channel: 146)
      XCTAssertTrue(harness.shouldInterceptClient(reused))
      XCTAssertThrowsError(try harness.sendClientFrame(reused)) {
        XCTAssertEqual(
          $0 as? BazelBuildServiceRouterProtocolError,
          .clientChannelReuse(146)
        )
      }
    }

    do {
      let harness = RouterHarness(fixture: fixture)
      harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
      let native = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 148
      )
      XCTAssertTrue(try harness.sendClient(native, channel: 149))
      XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
      XCTAssertFalse(try harness.sendService(BuildCreated(id: 1_489), channel: 149))
      let reused = RouterHarness.frame(
        BuildCancelRequest(sessionHandle: native.sessionHandle, id: 1_489),
        channel: 148
      )
      XCTAssertTrue(harness.shouldInterceptClient(reused))
      XCTAssertThrowsError(try harness.sendClientFrame(reused)) {
        XCTAssertEqual(
          $0 as? BazelBuildServiceRouterProtocolError,
          .clientChannelReuse(148)
        )
      }
      XCTAssertFalse(
        try harness.sendService(
          BuildOperationEnded(id: 1_489, status: .succeeded),
          channel: 148
        )
      )
      let retiredReuse = RouterHarness.frame(VoidResponse(), channel: 148)
      XCTAssertTrue(harness.shouldInterceptClient(retiredReuse))
      XCTAssertThrowsError(try harness.sendClientFrame(retiredReuse)) {
        XCTAssertEqual(
          $0 as? BazelBuildServiceRouterProtocolError,
          .clientChannelReuse(148)
        )
      }
    }

    do {
      let harness = RouterHarness(fixture: fixture, queryTimeout: 5)
      harness.automaticallyRespondToSettings = false
      let resolving = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 150
      )
      XCTAssertTrue(try harness.sendClient(resolving, channel: 151))
      XCTAssertTrue(harness.waitForNativeMessage(AllExportedMacrosAndValuesRequest.name))
      let duplicate = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 152
      )
      let reused = RouterHarness.frame(duplicate, channel: 151)
      XCTAssertTrue(harness.shouldInterceptClient(reused))
      XCTAssertThrowsError(try harness.sendClientFrame(reused)) {
        XCTAssertEqual(
          $0 as? BazelBuildServiceRouterProtocolError,
          .clientChannelReuse(151)
        )
      }
      harness.router.shutdown()
      XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 0.5))
    }
  }

  func testPrivateQueryTimeoutAndEveryLateShapeRemainConsumed() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture, queryTimeout: 0.01)
    harness.automaticallyRespondToSettings = false
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 601
    )

    XCTAssertTrue(try harness.sendClient(request, channel: 141))
    XCTAssertEqual(try harness.messageName(on: 141), ErrorResponse.name)
    let query = try XCTUnwrap(harness.nativeFrames.last)
    XCTAssertGreaterThanOrEqual(query.channel, UInt64(1) << 63)
    let xcodeCount = harness.xcodeFrames.count

    for message in [
      SwiftBuildProtocolCodec.encode(BoolResponse(true)),
      SwiftBuildProtocolCodec.encode(AllExportedMacrosAndValuesResponse(result: [:])),
      SwiftBuildProtocolCodec.encode(ErrorResponse("late")),
    ] {
      let late = BuildServiceRawFrame(channel: query.channel, payload: message)
      XCTAssertTrue(
        harness.router.shouldIntercept(
          direction: .serviceToClient,
          channel: late.channel,
          payloadLength: UInt32(late.payload.count),
          messageName: try harness.messageName(late)
        ))
      XCTAssertTrue(try harness.sendServiceFrame(late))
    }
    XCTAssertEqual(harness.xcodeFrames.count, xcodeCount)
  }

  func testCancelBeforeStartAcknowledgesAndEmitsOnlyOneCancelledTerminal() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithEvents)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 701
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 151))
    XCTAssertEqual(try harness.createdID(on: 151), -1)

    let cancel = BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1)
    XCTAssertTrue(try harness.sendClient(cancel, channel: 152))
    XCTAssertEqual(try harness.messageName(on: 152), VoidResponse.name)
    XCTAssertEqual(executor.executionCount, 0)
    let firstEventNames = try harness.xcodeFrames(on: 701).map(harness.messageName)
    XCTAssertEqual(firstEventNames, [BuildOperationEnded.name])
    let terminal = try SwiftBuildProtocolCodec.decodeBuildOperationEnded(
      try XCTUnwrap(harness.xcodeFrames(on: 701).first).payload
    )
    XCTAssertEqual(terminal.status, .cancelled)

    XCTAssertTrue(try harness.sendClient(cancel, channel: 153))
    XCTAssertEqual(try harness.messageName(on: 153), VoidResponse.name)
    XCTAssertEqual(
      try harness.xcodeFrames(on: 701).map(harness.messageName),
      [BuildOperationEnded.name]
    )
  }

  func testDeleteCancelsRunningProxyThenForwardsExactDeleteAfterTerminal() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForCancellation)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 801
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 161))
    XCTAssertEqual(try harness.createdID(on: 161), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 162
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)

    let delete = RouterHarness.frame(
      DeleteSessionRequest(sessionHandle: request.sessionHandle),
      channel: 163
    )
    XCTAssertTrue(try harness.sendClientFrame(delete))
    XCTAssertTrue(harness.waitForNativeMessage(DeleteSessionRequest.name))
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    let deleteEntry = try XCTUnwrap(
      harness.entries.first {
        $0.direction == .native && $0.frame.messageName == DeleteSessionRequest.name
      }
    )
    let terminalEntry = try XCTUnwrap(
      harness.entries.first {
        $0.direction == .xcode && $0.frame.messageName == BuildOperationEnded.name
      }
    )
    XCTAssertLessThan(terminalEntry.sequence, deleteEntry.sequence)
    XCTAssertEqual(deleteEntry.frame, delete)
    let terminal = try SwiftBuildProtocolCodec.decodeBuildOperationEnded(
      terminalEntry.frame.payload)
    XCTAssertEqual(terminal.status, .cancelled)
    XCTAssertEqual(
      harness.xcodeFrames(on: 801).filter { $0.messageName == BuildOperationEnded.name }.count,
      1
    )
  }

  func testUnknownAndWrongSessionOwnedIDsForwardToNative() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 901
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 171))
    XCTAssertEqual(try harness.createdID(on: 171), -1)
    XCTAssertFalse(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: "OTHER", id: -1),
        channel: 172
      )
    )
    XCTAssertFalse(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -999),
        channel: 173
      )
    )
  }

  func testSettingsResolutionDoesNotBlockDeleteAndDeleteWaitsForResolutionExit() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture, queryTimeout: 5)
    harness.automaticallyRespondToSettings = false
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_001
    )

    let createStart = Date()
    XCTAssertTrue(try harness.sendClient(request, channel: 181))
    XCTAssertLessThan(Date().timeIntervalSince(createStart), 0.25)
    XCTAssertTrue(harness.waitForNativeMessage(AllExportedMacrosAndValuesRequest.name))

    let delete = RouterHarness.frame(
      DeleteSessionRequest(sessionHandle: request.sessionHandle),
      channel: 182
    )
    let deleteStart = Date()
    XCTAssertTrue(try harness.sendClientFrame(delete))
    XCTAssertLessThan(Date().timeIntervalSince(deleteStart), 0.25)
    XCTAssertTrue(harness.waitForNativeMessage(DeleteSessionRequest.name))
    XCTAssertEqual(harness.nativeFrames.last, delete)
    XCTAssertTrue(harness.xcodeFrames(on: 1_001).contains { $0.messageName == ErrorResponse.name })
    XCTAssertTrue(harness.xcodeFrames(on: 181).contains { $0.messageName == ErrorResponse.name })
    XCTAssertFalse(harness.xcodeFrames.contains { $0.messageName == BuildCreated.name })

    let registrationErrors = harness.entries.filter {
      $0.direction == .xcode && [UInt64(1_001), UInt64(181)].contains($0.frame.channel)
    }
    XCTAssertEqual(registrationErrors.map(\.frame.channel), [1_001, 181])
    let deleteEntry = try XCTUnwrap(
      harness.entries.first {
        $0.direction == .native && $0.frame.messageName == DeleteSessionRequest.name
      }
    )
    XCTAssertLessThan(try XCTUnwrap(registrationErrors.last).sequence, deleteEntry.sequence)
  }

  func testCancellationWinsTerminalRaceBeforeExecutorReturns() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForCancellation)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_011
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 183))
    XCTAssertEqual(try harness.createdID(on: 183), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 184
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)

    XCTAssertTrue(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 185
      )
    )
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    let terminals = try harness.xcodeFrames(on: 1_011)
      .filter { $0.messageName == BuildOperationEnded.name }
      .map { try harness.decode($0, as: BuildOperationEnded.self) }
    XCTAssertEqual(terminals.map(\.status), [.cancelled])
    let wrapperEnded = try XCTUnwrap(
      harness.xcodeFrames(on: 1_011)
        .filter { $0.messageName == BuildOperationTaskEnded.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskEnded.self) }
        .first { $0.id == 1 }
    )
    XCTAssertFalse(wrapperEnded.signalled)
  }

  func testCompletionWinsTerminalRaceBeforeCancel() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForReleaseThenSucceed)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let taskEndedAttempt = DispatchSemaphore(value: 0)
    let allowTaskEnded = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 1_021,
        (try? harness.messageName(frame)) == BuildOperationTaskEnded.name
      else {
        return
      }
      taskEndedAttempt.signal()
      _ = allowTaskEnded.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_021
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 186))
    XCTAssertEqual(try harness.createdID(on: 186), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 187
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
    executor.release.signal()
    XCTAssertEqual(taskEndedAttempt.wait(timeout: .now() + 2), .success)

    XCTAssertTrue(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 188
      )
    )
    XCTAssertEqual(try harness.messageName(on: 188), VoidResponse.name)
    allowTaskEnded.signal()
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    let terminals = try harness.xcodeFrames(on: 1_021)
      .filter { $0.messageName == BuildOperationEnded.name }
      .map { try harness.decode($0, as: BuildOperationEnded.self) }
    XCTAssertEqual(terminals.map(\.status), [.succeeded])
  }

  func testOversizedUnrelatedNativeEventOnTrackedChannelRemainsTransparent() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let native = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_031
    )
    XCTAssertTrue(try harness.sendClient(native, channel: 189))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    XCTAssertFalse(try harness.sendService(BuildCreated(id: 99), channel: 189))

    XCTAssertFalse(
      harness.router.shouldIntercept(
        direction: .serviceToClient,
        channel: 1_031,
        payloadLength: UInt32.max,
        messageName: BuildOperationConsoleOutputEmitted.name
      )
    )
  }

  func testDeleteReplyClearsSessionSoItCanBeReused() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_041
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 190))
    XCTAssertEqual(try harness.createdID(on: 190), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 191
      )
    )
    let delete = DeleteSessionRequest(sessionHandle: request.sessionHandle)
    XCTAssertTrue(try harness.sendClient(delete, channel: 192))
    XCTAssertTrue(harness.waitForNativeMessage(DeleteSessionRequest.name))
    XCTAssertFalse(try harness.sendService(VoidResponse(), channel: 192))

    let reused = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_042
    )
    XCTAssertTrue(try harness.sendClient(reused, channel: 193))
    XCTAssertEqual(try harness.createdID(on: 193), -2)
  }

  func testShutdownCancelsAndQuiescesRunningOwnedWork() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForReleaseThenSucceed)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_051
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 194))
    XCTAssertEqual(try harness.createdID(on: 194), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 195
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)

    harness.router.shutdown()
    executor.release.signal()
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 2))
  }

  func testBuildCreatedPublicationAndStartEligibilityAreAtomic() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForCancellation)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let publicationEntered = DispatchSemaphore(value: 0)
    let releasePublication = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 196,
        (try? harness.messageName(frame)) == BuildCreated.name
      else { return }
      publicationEntered.signal()
      _ = releasePublication.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_061
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 196))
    XCTAssertEqual(publicationEntered.wait(timeout: .now() + 2), .success)

    let startFinished = DispatchSemaphore(value: 0)
    let startResult = ThreadSafeResultBox<Bool>()
    DispatchQueue.global(qos: .userInitiated).async {
      startResult.store(
        Result {
          try harness.sendClient(
            BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
            channel: 197
          )
        }
      )
      startFinished.signal()
    }
    XCTAssertEqual(startFinished.wait(timeout: .now() + 0.02), .timedOut)
    releasePublication.signal()
    XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(try XCTUnwrap(startResult.value).get())
    XCTAssertEqual(try harness.messageName(on: 197), VoidResponse.name)
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 198
      )
    )
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
  }

  func testPublishingShutdownEmitsNoEventBeforePinnedClientInstallsBuildID() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let publicationEntered = DispatchSemaphore(value: 0)
    let releasePublication = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 1_062,
        (try? harness.messageName(frame)) == BuildCreated.name
      else { return }
      publicationEntered.signal()
      _ = releasePublication.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_063
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 1_062))
    XCTAssertEqual(publicationEntered.wait(timeout: .now() + 2), .success)

    harness.router.shutdown()
    releasePublication.signal()
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 2))

    let frames = harness.entries
      .filter {
        $0.direction == .xcode && [UInt64(1_062), UInt64(1_063)].contains($0.frame.channel)
      }
      .sorted { $0.sequence < $1.sequence }
      .map(\.frame)
    XCTAssertEqual(try frames.map(harness.messageName), [BuildCreated.name])

    var deferredBuildID: Int?
    var installedBuildID: Int?
    var clientStateIsRequested = true
    for frame in frames {
      let message = try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload).message
      if frame.channel == 1_062 {
        deferredBuildID = try XCTUnwrap(message as? BuildCreated).id
      } else {
        if message is ErrorResponse {
          clientStateIsRequested = false
        }
        XCTAssertTrue(
          installedBuildID != nil || message is ErrorResponse,
          "Pinned SwiftBuild accepts only ErrorResponse before its CreateBuild continuation installs the ID"
        )
      }
    }
    XCTAssertTrue(
      clientStateIsRequested,
      "Pinned SwiftBuild requires requested state when the CreateBuild continuation resumes"
    )
    installedBuildID = deferredBuildID
    XCTAssertEqual(installedBuildID, -1)
  }

  func testNativeFallbackCreatePrecedesDeleteAcrossBlockedSink() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let createSendEntered = DispatchSemaphore(value: 0)
    let releaseCreateSend = DispatchSemaphore(value: 0)
    harness.beforeNativeSend = { frame in
      guard frame.channel == 199, frame.messageName == CreateBuildRequest.name else { return }
      createSendEntered.signal()
      _ = releaseCreateSend.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_071
    )
    let createFrame = RouterHarness.frame(request, channel: 199)
    XCTAssertTrue(try harness.sendClientFrame(createFrame))
    XCTAssertEqual(createSendEntered.wait(timeout: .now() + 2), .success)

    let deleteFrame = RouterHarness.frame(
      DeleteSessionRequest(sessionHandle: request.sessionHandle),
      channel: 200
    )
    XCTAssertTrue(try harness.sendClientFrame(deleteFrame))
    XCTAssertFalse(harness.nativeFrames.contains { $0 == deleteFrame })
    releaseCreateSend.signal()
    XCTAssertTrue(harness.waitForNativeMessage(DeleteSessionRequest.name))
    let createEntry = try XCTUnwrap(harness.entries.first { $0.frame == createFrame })
    let deleteEntry = try XCTUnwrap(harness.entries.first { $0.frame == deleteFrame })
    XCTAssertLessThan(createEntry.sequence, deleteEntry.sequence)
  }

  func testPostCommitSuccessWinsCancellationAndRetainsCapacityUntilTerminal() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForReleaseThenSucceed)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_081
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 201))
    XCTAssertEqual(try harness.createdID(on: 201), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 202
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(
      try harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 203
      )
    )

    let competing = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_082
    )
    XCTAssertTrue(try harness.sendClient(competing, channel: 204))
    XCTAssertEqual(try harness.messageName(on: 1_082), ErrorResponse.name)
    XCTAssertEqual(try harness.messageName(on: 204), ErrorResponse.name)

    executor.release.signal()
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    let terminal = try XCTUnwrap(
      harness.xcodeFrames(on: 1_081).first { $0.messageName == BuildOperationEnded.name }
    )
    XCTAssertEqual(
      try harness.decode(terminal, as: BuildOperationEnded.self).status,
      .succeeded
    )
  }

  func testMalformedNativeTerminalDoesNotRetainRouterLock() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_091
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 205))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    XCTAssertFalse(try harness.sendService(BuildCreated(id: 77), channel: 205))
    let malformed = BuildServiceRawFrame(
      channel: 1_091,
      payload: SwiftBuildProtocolCodec.encode(BoolResponse(true)),
      messageName: BuildOperationEnded.name
    )
    XCTAssertThrowsError(try harness.sendServiceFrame(malformed))
    harness.router.shutdown()
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 0.2))
  }

  func testRetiredPrivateChannelRejectsClientRPCReuse() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture, queryTimeout: 0.01)
    harness.automaticallyRespondToSettings = false
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_101
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 206))
    XCTAssertEqual(try harness.messageName(on: 206), ErrorResponse.name)
    let queryChannel = try XCTUnwrap(
      harness.nativeFrames.first { $0.messageName == AllExportedMacrosAndValuesRequest.name }
    ).channel
    let nativeCount = harness.nativeFrames.count

    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: 999),
        channel: queryChannel
      )
    )
    XCTAssertEqual(try harness.messageName(on: queryChannel), ErrorResponse.name)
    XCTAssertEqual(harness.nativeFrames.count, nativeCount)

    let ping = RouterHarness.frame(VoidResponse(), channel: queryChannel)
    XCTAssertTrue(
      harness.router.shouldIntercept(
        direction: .clientToService,
        channel: queryChannel,
        payloadLength: UInt32(ping.payload.count),
        messageName: ping.messageName
      )
    )
    XCTAssertTrue(try harness.sendClientFrame(ping))
    XCTAssertEqual(harness.nativeFrames.count, nativeCount)
    XCTAssertEqual(
      harness.xcodeFrames(on: queryChannel).filter { $0.messageName == ErrorResponse.name }.count,
      2
    )
  }

  func testShutdownCancelsAndQuiescesResolvingWork() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture, queryTimeout: 5)
    harness.automaticallyRespondToSettings = false
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_111
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 207))
    XCTAssertTrue(harness.waitForNativeMessage(AllExportedMacrosAndValuesRequest.name))
    harness.router.shutdown()
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 0.5))
  }

  func testWrongShapedNativeCreateReplyFailsClosedAndClearsPendingState() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
    let native = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_121
    )
    XCTAssertTrue(try harness.sendClient(native, channel: 208))
    XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
    let wrong = RouterHarness.frame(BoolResponse(true), channel: 208)
    XCTAssertTrue(
      harness.router.shouldIntercept(
        direction: .serviceToClient,
        channel: wrong.channel,
        payloadLength: UInt32(wrong.payload.count),
        messageName: wrong.messageName
      )
    )
    XCTAssertThrowsError(try harness.sendServiceFrame(wrong)) {
      XCTAssertEqual(
        $0 as? BazelBuildServiceRouterProtocolError,
        .unexpectedNativeResponse(channel: 208, messageName: BoolResponse.name)
      )
    }

    harness.settingsOverrides.removeValue(forKey: "PROJECT_FILE_PATH")
    let mapped = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_122
    )
    XCTAssertTrue(try harness.sendClient(mapped, channel: 209))
    XCTAssertEqual(try harness.createdID(on: 209), -1)
  }

  func testOversizedNativeControlFramesFailClosedAndRetireBookkeeping() throws {
    let fixture = try PlanBuilderFixture()

    do {
      let harness = RouterHarness(fixture: fixture)
      harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
      let native = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 1_131
      )
      XCTAssertTrue(try harness.sendClient(native, channel: 210))
      XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
      XCTAssertThrowsError(
        try harness.router.interceptionDidFail(
          direction: .serviceToClient,
          channel: 210,
          messageName: BuildCreated.name,
          failure: .capturedPayloadTooLarge(actualBytes: UInt32.max, maximumBytes: 1_024)
        )
      )
    }

    do {
      let harness = RouterHarness(fixture: fixture)
      harness.settingsOverrides["PROJECT_FILE_PATH"] = "/tmp/Unrelated.xcodeproj"
      let native = makeCreateBuildRequest(
        targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
        responseChannel: 1_132
      )
      XCTAssertTrue(try harness.sendClient(native, channel: 211))
      XCTAssertTrue(harness.waitForNativeMessage(CreateBuildRequest.name))
      XCTAssertFalse(try harness.sendService(BuildCreated(id: 88), channel: 211))
      XCTAssertThrowsError(
        try harness.router.interceptionDidFail(
          direction: .serviceToClient,
          channel: 1_132,
          messageName: BuildOperationEnded.name,
          failure: .capturedPayloadTooLarge(actualBytes: UInt32.max, maximumBytes: 1_024)
        )
      )
    }

    do {
      let harness = RouterHarness(fixture: fixture)
      XCTAssertFalse(
        try harness.sendClient(
          DeleteSessionRequest(sessionHandle: "DELETE_SESSION"),
          channel: 212
        )
      )
      XCTAssertThrowsError(
        try harness.router.interceptionDidFail(
          direction: .serviceToClient,
          channel: 212,
          messageName: VoidResponse.name,
          failure: .capturedPayloadTooLarge(actualBytes: UInt32.max, maximumBytes: 1_024)
        )
      )
    }
  }

  func testOversizedPrivateQueryIsConsumedAndFailsResolution() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture, queryTimeout: 5)
    harness.automaticallyRespondToSettings = false
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_141
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 213))
    XCTAssertTrue(harness.waitForNativeMessage(AllExportedMacrosAndValuesRequest.name))
    let queryChannel = try XCTUnwrap(harness.nativeFrames.last).channel
    XCTAssertTrue(
      try harness.router.interceptionDidFail(
        direction: .serviceToClient,
        channel: queryChannel,
        messageName: AllExportedMacrosAndValuesResponse.name,
        failure: .capturedPayloadTooLarge(actualBytes: UInt32.max, maximumBytes: 1_024)
      )
    )
    XCTAssertEqual(try harness.messageName(on: 213), ErrorResponse.name)
  }

  func testWrapperTaskIsSignalledOnlyForActualSignalTermination() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .signalledCancellation)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_151
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 214))
    XCTAssertEqual(try harness.createdID(on: 214), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 215
      )
    )
    XCTAssertTrue(harness.waitForXcodeMessage(BuildOperationEnded.name))
    let wrapperEnded = try XCTUnwrap(
      harness.xcodeFrames(on: 1_151)
        .filter { $0.messageName == BuildOperationTaskEnded.name }
        .compactMap { try? harness.decode($0, as: BuildOperationTaskEnded.self) }
        .first { $0.id == 1 }
    )
    XCTAssertTrue(wrapperEnded.signalled)
  }

  func testPendingCancelAndShutdownHaveOneTerminalEmitter() throws {
    let fixture = try PlanBuilderFixture()
    let harness = RouterHarness(fixture: fixture)
    let terminalEntered = DispatchSemaphore(value: 0)
    let releaseTerminal = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 1_161,
        (try? harness.messageName(frame)) == BuildOperationEnded.name
      else { return }
      terminalEntered.signal()
      _ = releaseTerminal.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_161
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 216))
    XCTAssertEqual(try harness.createdID(on: 216), -1)

    let cancelFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      _ = try? harness.sendClient(
        BuildCancelRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 217
      )
      cancelFinished.signal()
    }
    XCTAssertEqual(terminalEntered.wait(timeout: .now() + 2), .success)
    harness.router.shutdown()
    releaseTerminal.signal()
    XCTAssertEqual(cancelFinished.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 2))
    XCTAssertEqual(
      harness.xcodeFrames(on: 1_161).filter { $0.messageName == BuildOperationEnded.name }.count,
      1
    )
  }

  func testTerminalReservationReleasesCapacityBeforeFinalFrameCompletes() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .waitForReleaseThenSucceed)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let terminalEntered = DispatchSemaphore(value: 0)
    let releaseTerminal = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 1_171,
        (try? harness.messageName(frame)) == BuildOperationEnded.name
      else { return }
      terminalEntered.signal()
      _ = releaseTerminal.wait(timeout: .now() + 2)
    }
    let first = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_171
    )
    XCTAssertTrue(try harness.sendClient(first, channel: 218))
    XCTAssertEqual(try harness.createdID(on: 218), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: first.sessionHandle, id: -1),
        channel: 219
      )
    )
    XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
    executor.release.signal()
    XCTAssertEqual(terminalEntered.wait(timeout: .now() + 2), .success)

    let second = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_172
    )
    XCTAssertTrue(try harness.sendClient(second, channel: 220))
    XCTAssertEqual(try harness.createdID(on: 220), -2)
    releaseTerminal.signal()
  }

  func testShutdownDoesNotWaitForBlockedEventOutputWhileHoldingRouterState() throws {
    let fixture = try PlanBuilderFixture()
    let executor = RouterFakeExecutor(behavior: .succeedWithEvents)
    let harness = RouterHarness(fixture: fixture, executor: executor)
    let outputEntered = DispatchSemaphore(value: 0)
    let releaseOutput = DispatchSemaphore(value: 0)
    harness.beforeXcodeSend = { frame in
      guard frame.channel == 1_181,
        (try? harness.messageName(frame)) == BuildOperationConsoleOutputEmitted.name
      else { return }
      outputEntered.signal()
      _ = releaseOutput.wait(timeout: .now() + 2)
    }
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      responseChannel: 1_181
    )
    XCTAssertTrue(try harness.sendClient(request, channel: 221))
    XCTAssertEqual(try harness.createdID(on: 221), -1)
    XCTAssertTrue(
      try harness.sendClient(
        BuildStartRequest(sessionHandle: request.sessionHandle, id: -1),
        channel: 222
      )
    )
    XCTAssertEqual(outputEntered.wait(timeout: .now() + 2), .success)

    let shutdownStarted = Date()
    harness.router.shutdown()
    XCTAssertLessThan(Date().timeIntervalSince(shutdownStarted), 0.25)
    releaseOutput.signal()
    XCTAssertTrue(harness.router.buildServiceRelayWaitForQuiescence(timeout: 2))
  }

  func testConfigurationRequiresCompleteLauncherEnvironment() {
    XCTAssertThrowsError(
      try BazelBuildServiceRouterConfiguration.loadIfEnabled(
        environment: [
          BazelBuildServiceRouterConfiguration.manifestEnvironmentKey: "/tmp/manifest.json"
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? BazelBuildServiceRouterConfigurationError,
        .incompleteEnvironment
      )
    }
    XCTAssertNoThrow(
      try BazelBuildServiceRouterConfiguration.loadIfEnabled(environment: [:])
    )
  }
}

private final class RouterFakeExecutor: BazelOperationExecuting, @unchecked Sendable {
  enum Behavior {
    case signalledCancellation
    case succeedWithDetailedActions
    case succeedWithEvents
    case waitForReleaseThenSucceed
    case waitForCancellation
  }

  let release = DispatchSemaphore(value: 0)
  let started = DispatchSemaphore(value: 0)
  private let behavior: Behavior
  private let lock = NSLock()
  private var count = 0
  private var recordedOperationIDs = [String]()

  var executionCount: Int {
    lock.withLock { count }
  }

  var operationIDs: [String] {
    lock.withLock { recordedOperationIDs }
  }

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func execute(
    plan: ResolvedBuildPlan,
    processEnvironment: [String: String],
    onEvent: @escaping @Sendable (BazelOperationExecutionEvent) async throws -> Void
  ) async -> BazelOperationExecutionResult {
    lock.withLock {
      count += 1
      recordedOperationIDs.append(plan.operationID)
    }
    started.signal()
    switch behavior {
    case .signalledCancellation:
      return BazelOperationExecutionResult(
        processCompletion: ProcessCompletion(
          cancellationRequested: true,
          processGroupID: 1,
          processIdentifier: 1,
          standardErrorBytes: 0,
          standardOutputBytes: 0,
          outputDisposition: .complete,
          termination: .signalled(signal: SIGTERM)
        ),
        status: .cancelled
      )
    case .succeedWithEvents:
      do {
        try await onEvent(
          .processOutput(
            ProcessOutputEvent(
              bytes: Data("bazel output\n".utf8),
              channel: .standardOutput,
              sequence: 1
            )
          )
        )
        try await onEvent(
          .bep(.progress(ProxyProgress(completed: 1, source: .interactiveHint, total: 2))))
        try await onEvent(
          .bep(
            .actionCompleted(
              BEPActionCompleted(
                configuration: "debug",
                identity: "//app:App|App.app|debug",
                label: "//app:App",
                mnemonic: "SwiftCompile",
                primaryOutput: "App.app",
                succeeded: true
              )
            )
          )
        )
        try await onEvent(
          .action(
            BazelPresentedAction(
              upToDate: BazelConfiguredAction(
                configuration: "debug",
                label: "//app:App",
                mnemonic: "CppArchive",
                primaryOutput: "libApp.a"
              )
            )
          )
        )
        try await onEvent(
          .actionSummary(
            BazelActionPresentationSummary(
              completedStatusUnavailable: 1,
              executed: 0,
              presented: 2,
              upToDate: 1
            )
          )
        )
        try await onEvent(.bep(.reportedExecutedActionCount(1)))
        try await onEvent(.bep(.finished(succeeded: true)))
        return BazelOperationExecutionResult(status: .succeeded)
      } catch {
        return BazelOperationExecutionResult(
          failure: BazelOperationFailure(phase: .presentation, message: error.localizedDescription),
          status: .failed
        )
      }
    case .succeedWithDetailedActions:
      do {
        let swift = BazelConfiguredAction(
          commandLineDisplayString: "configured-swiftc",
          configuration: "debug",
          label: "//app:App",
          mnemonic: "SwiftCompile",
          primaryOutput: "App.swiftmodule"
        )
        try await onEvent(
          .action(
            BazelPresentedAction(
              configured: swift,
              executionRecord: BazelExecutionRecord(
                cacheHit: true,
                commandLineDisplayString: "actual-swiftc -c Input.swift",
                exitCode: 0,
                listedOutputs: ["App.swiftmodule"],
                mnemonic: "SwiftCompile",
                runner: "remote cache hit",
                status: nil,
                targetLabel: "//app:App"
              )
            )
          )
        )
        let link = BazelConfiguredAction(
          configuration: "debug",
          label: "//app:App",
          mnemonic: "ObjcLink",
          primaryOutput: "App"
        )
        try await onEvent(
          .action(
            BazelPresentedAction(
              configured: link,
              executionRecord: BazelExecutionRecord(
                cacheHit: false,
                commandLineDisplayString: "actual-clang -o App",
                exitCode: 0,
                listedOutputs: ["App"],
                mnemonic: "ObjcLink",
                runner: "worker",
                status: "SUCCESS",
                targetLabel: "//app:App"
              )
            )
          )
        )
        try await onEvent(
          .actionSummary(
            BazelActionPresentationSummary(
              cacheHits: 1,
              executed: 1,
              presented: 2,
              upToDate: 0
            )
          )
        )
        try await onEvent(.bep(.finished(succeeded: true)))
        return BazelOperationExecutionResult(status: .succeeded)
      } catch {
        return BazelOperationExecutionResult(
          failure: BazelOperationFailure(phase: .presentation, message: error.localizedDescription),
          status: .failed
        )
      }
    case .waitForCancellation:
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
      return BazelOperationExecutionResult(status: .cancelled)
    case .waitForReleaseThenSucceed:
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { [release] in
          _ = release.wait(timeout: .now() + 5)
          continuation.resume()
        }
      }
      return BazelOperationExecutionResult(status: .succeeded)
    }
  }
}

private final class RouterHarness: @unchecked Sendable {
  enum HarnessError: Error {
    case deallocated
  }

  enum Direction: Equatable {
    case native
    case xcode
  }

  struct Entry {
    let direction: Direction
    let frame: BuildServiceRawFrame
    let sequence: Int
  }

  let router: BazelBuildServiceRouter
  var automaticallyRespondToSettings = true
  var beforeNativeSend: ((BuildServiceRawFrame) -> Void)?
  var beforeXcodeSend: ((BuildServiceRawFrame) -> Void)?
  var settingsOverrides = [String: String]()

  private let condition = NSCondition()
  private let fixture: PlanBuilderFixture
  private var recordedEntries = [Entry]()
  private var nextSequence = 1

  lazy var outputs = BuildServiceFrameOutputs(
    sendToNative: { [weak self] frame in
      guard let self else { throw HarnessError.deallocated }
      self.beforeNativeSend?(frame)
      self.record(.native, frame: frame)
      self.respondToSettingsIfNeeded(frame)
    },
    sendToXcode: { [weak self] frame in
      guard let self else { throw HarnessError.deallocated }
      self.beforeXcodeSend?(frame)
      self.record(.xcode, frame: frame)
    }
  )

  var entries: [Entry] {
    condition.lock()
    defer { condition.unlock() }
    return recordedEntries
  }

  var nativeFrames: [BuildServiceRawFrame] {
    entries.filter { $0.direction == .native }.map(\.frame)
  }

  var xcodeFrames: [BuildServiceRawFrame] {
    entries.filter { $0.direction == .xcode }.map(\.frame)
  }

  init(
    fixture: PlanBuilderFixture,
    executor: any BazelOperationExecuting = RouterFakeExecutor(behavior: .succeedWithEvents),
    queryTimeout: TimeInterval = 1
  ) {
    self.fixture = fixture
    router = BazelBuildServiceRouter(
      configuration: BazelBuildServiceRouterConfiguration(
        manifestURL: fixture.manifestURL,
        verifiedManifest: fixture.verifiedManifest
      ),
      executor: executor,
      processEnvironment: [:],
      queryTimeout: queryTimeout
    )
  }

  func sendClient<M: Message>(_ message: M, channel: UInt64) throws -> Bool {
    try sendClientFrame(Self.frame(message, channel: channel))
  }

  func sendClientFrame(_ frame: BuildServiceRawFrame) throws -> Bool {
    try router.intercept(direction: .clientToService, frame: frame, outputs: outputs)
  }

  func shouldInterceptClient(_ frame: BuildServiceRawFrame) -> Bool {
    router.shouldIntercept(
      direction: .clientToService,
      channel: frame.channel,
      payloadLength: UInt32(frame.payload.count),
      messageName: frame.messageName
    )
  }

  func sendService<M: Message>(_ message: M, channel: UInt64) throws -> Bool {
    try sendServiceFrame(Self.frame(message, channel: channel))
  }

  func sendServiceFrame(_ frame: BuildServiceRawFrame) throws -> Bool {
    try router.intercept(direction: .serviceToClient, frame: frame, outputs: outputs)
  }

  func createdID(on channel: UInt64) throws -> Int {
    XCTAssertTrue(waitForXcodeChannel(channel))
    return try SwiftBuildProtocolCodec.decodeBuildCreated(
      try XCTUnwrap(xcodeFrames.first { $0.channel == channel }).payload
    ).id
  }

  func xcodeFrames(on channel: UInt64) -> [BuildServiceRawFrame] {
    xcodeFrames.filter { $0.channel == channel }
  }

  func xcodeMessageNames() -> [String] {
    xcodeFrames.compactMap(\.messageName)
  }

  func messageName(on channel: UInt64) throws -> String {
    XCTAssertTrue(waitForXcodeChannel(channel))
    return try messageName(try XCTUnwrap(xcodeFrames.first { $0.channel == channel }))
  }

  func messageName(_ frame: BuildServiceRawFrame) throws -> String {
    type(of: try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload).message).name
  }

  func decode<M: Message>(_ frame: BuildServiceRawFrame, as type: M.Type) throws -> M {
    try XCTUnwrap(try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload).message as? M)
  }

  func waitForXcodeMessage(_ name: String, timeout: TimeInterval = 2) -> Bool {
    waitForEntry(direction: .xcode, name: name, timeout: timeout)
  }

  func waitForNativeMessage(_ name: String, timeout: TimeInterval = 2) -> Bool {
    waitForEntry(direction: .native, name: name, timeout: timeout)
  }

  func waitForXcodeChannel(_ channel: UInt64, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    while !recordedEntries.contains(where: {
      $0.direction == .xcode && $0.frame.channel == channel
    }) {
      if !condition.wait(until: deadline) {
        condition.unlock()
        return false
      }
    }
    condition.unlock()
    return true
  }

  static func frame<M: Message>(_ message: M, channel: UInt64) -> BuildServiceRawFrame {
    BuildServiceRawFrame(
      channel: channel,
      payload: SwiftBuildProtocolCodec.encode(message),
      messageName: M.name
    )
  }

  private func record(_ direction: Direction, frame: BuildServiceRawFrame) {
    let namedFrame: BuildServiceRawFrame
    if frame.messageName == nil,
      let name = try? messageName(frame)
    {
      namedFrame = BuildServiceRawFrame(
        channel: frame.channel,
        payload: frame.payload,
        messageName: name
      )
    } else {
      namedFrame = frame
    }
    condition.lock()
    recordedEntries.append(
      Entry(direction: direction, frame: namedFrame, sequence: nextSequence)
    )
    nextSequence += 1
    condition.broadcast()
    condition.unlock()
  }

  private func respondToSettingsIfNeeded(_ frame: BuildServiceRawFrame) {
    guard automaticallyRespondToSettings,
      let message = try? SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload).message,
      let request = message as? AllExportedMacrosAndValuesRequest
    else { return }
    let targetGUID: String
    guard case .components(let level, _) = request.context,
      case .target(let guid) = level
    else { return }
    targetGUID = guid
    var values = Dictionary(
      uniqueKeysWithValues: fixture.snapshot(targetGUID: targetGUID).values.map {
        ($0.key, $0.value)
      }
    )
    values.merge(settingsOverrides) { _, new in new }
    let response = Self.frame(
      AllExportedMacrosAndValuesResponse(result: values),
      channel: frame.channel
    )
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      _ = try? self.sendServiceFrame(response)
    }
  }

  private func waitForEntry(
    direction: Direction,
    name: String,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    while !recordedEntries.contains(where: {
      $0.direction == direction && $0.frame.messageName == name
    }) {
      if !condition.wait(until: deadline) {
        condition.unlock()
        return false
      }
    }
    condition.unlock()
    return true
  }
}

private final class ThreadSafeResultBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Result<Value, Error>?

  var value: Result<Value, Error>? {
    lock.withLock { storedValue }
  }

  func store(_ value: Result<Value, Error>) {
    lock.withLock { storedValue = value }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
