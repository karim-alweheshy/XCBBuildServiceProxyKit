import CryptoKit
import Foundation
import ModernBuildServiceProxyCore
import SWBProtocol
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class EvaluatedSettingsProbeTests: XCTestCase {
  func testProbeUsesHeldChannelAndForwardsOriginalBytesAfterRedactedSuccess() throws {
    let fixture = try ProbeFixture(environmentKeys: ["CUSTOM_SECRET", "HOME"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 14,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var serviceBoundFrames: [BuildServiceRawFrame] = []
    let keys = EvaluatedSettingsProbe.fixedPlanRoleKeys + ["CUSTOM_SECRET", "HOME"]
    let secretValues = makeValues(keys: keys, overrides: ["CUSTOM_SECRET": "private-value"])

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        serviceBoundFrames.append(frame)
        let macroRequest = try decodeMacroRequest(frame)
        XCTAssertEqual(frame.channel, original.channel)
        XCTAssertEqual(macroRequest.targetGUID, "TARGET-A")
        XCTAssertEqual(macroRequest.expressions, keys.map { "$(\($0))" })

        let response = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(
            MacroEvaluationResponse(result: .stringList(secretValues))
          ),
          messageName: MacroEvaluationResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
        )
      }
    )
    XCTAssertFalse(consumed)
    serviceBoundFrames.append(original)

    XCTAssertEqual(serviceBoundFrames.count, 2)
    XCTAssertEqual(serviceBoundFrames[0].channel, original.channel)
    XCTAssertEqual(serviceBoundFrames[1], original)

    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .succeeded)
    XCTAssertEqual(report.failureCodes, [])
    XCTAssertEqual(report.targetCount, 1)
    XCTAssertEqual(report.targets.count, 1)
    let secretMetadata = try XCTUnwrap(
      report.targets[0].settings.first { $0.key == "CUSTOM_SECRET" }
    )
    XCTAssertTrue(secretMetadata.present)
    XCTAssertEqual(secretMetadata.valueByteLength, 13)
    XCTAssertEqual(secretMetadata.valueSHA256, sha256("private-value"))

    let reportText = try String(contentsOf: fixture.reportURL, encoding: .utf8)
    XCTAssertFalse(reportText.contains("private-value"))
    XCTAssertFalse(reportText.contains("SESSION-1"))
    XCTAssertFalse(reportText.contains("TARGET-A"))
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.reportURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    XCTAssertEqual(permissions & 0o777, 0o600)
  }

  func testToolchainsUsesDedicatedOrderedStringListAndCanonicalizesForReport() throws {
    let fixture = try ProbeFixture(environmentKeys: ["BEFORE", "TOOLCHAINS", "AFTER"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 15,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    let scalarKeys = EvaluatedSettingsProbe.fixedPlanRoleKeys + ["BEFORE", "AFTER"]
    let listValues = ["toolchain-metal", "toolchain-default"]
    var serviceBoundFrames: [BuildServiceRawFrame] = []

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        serviceBoundFrames.append(frame)
        switch serviceBoundFrames.count {
        case 1:
          let scalarRequest = try decodeMacroRequest(frame)
          XCTAssertEqual(scalarRequest.expressions, scalarKeys.map { "$(\($0))" })
          XCTAssertFalse(scalarRequest.expressions.contains("$(TOOLCHAINS)"))
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: scalarKeys)),
            probe: probe
          )
        case 2:
          let listRequest = try decodeStringListMacroRequest(frame)
          XCTAssertEqual(listRequest.targetGUID, "TARGET-A")
          XCTAssertEqual(listRequest.parameters, request.request.parameters)
          XCTAssertEqual(listRequest.macroName, "TOOLCHAINS")
          try respond(to: frame, with: .stringList(listValues), probe: probe)
        default:
          XCTFail("Unexpected extra probe request")
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(serviceBoundFrames.count, 2)
    XCTAssertTrue(serviceBoundFrames.allSatisfy { $0.channel == original.channel })
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .succeeded)
    XCTAssertEqual(
      report.targets[0].settings.map(\.key),
      EvaluatedSettingsProbe.fixedPlanRoleKeys + ["BEFORE", "TOOLCHAINS", "AFTER"]
    )
    let metadata = try XCTUnwrap(
      report.targets[0].settings.first { $0.key == "TOOLCHAINS" }
    )
    let canonicalValue = listValues.joined(separator: " ")
    XCTAssertTrue(metadata.present)
    XCTAssertEqual(metadata.valueByteLength, canonicalValue.utf8.count)
    XCTAssertEqual(metadata.valueSHA256, sha256(canonicalValue))
    let reportText = try String(contentsOf: fixture.reportURL, encoding: .utf8)
    XCTAssertFalse(reportText.contains(listValues[0]))
    XCTAssertFalse(reportText.contains(listValues[1]))
  }

  func testEmptyToolchainsListCanonicalizesToAbsentEmptyString() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 16,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0

    XCTAssertFalse(
      try probe.intercept(
        direction: .clientToService,
        frame: original,
        send: { frame in
          requestCount += 1
          if requestCount == 1 {
            try respond(
              to: frame,
              with: .stringList(
                makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)
              ),
              probe: probe
            )
          } else {
            XCTAssertEqual(try decodeStringListMacroRequest(frame).macroName, "TOOLCHAINS")
            try respond(to: frame, with: .stringList([]), probe: probe)
          }
        }
      )
    )

    XCTAssertEqual(requestCount, 2)
    let metadata = try XCTUnwrap(
      fixture.readReport().targets[0].settings.first { $0.key == "TOOLCHAINS" }
    )
    XCTAssertFalse(metadata.present)
    XCTAssertEqual(metadata.valueByteLength, 0)
    XCTAssertEqual(metadata.valueSHA256, sha256(""))
  }

  func testToolchainsListDisagreementAcrossTargetsFailsSharedValueControl() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil),
        ConfiguredTargetMessagePayload(guid: "TARGET-B", parameters: nil),
      ]
    )
    let original = BuildServiceRawFrame(
      channel: 22,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let targetIndex = requestCount / 2
        requestCount += 1
        if requestCount % 2 == 1 {
          let scalarRequest = try decodeMacroRequest(frame)
          XCTAssertEqual(scalarRequest.targetGUID, "TARGET-\(targetIndex == 0 ? "A" : "B")")
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)),
            probe: probe
          )
        } else {
          let listRequest = try decodeStringListMacroRequest(frame)
          XCTAssertEqual(listRequest.macroName, "TOOLCHAINS")
          try respond(
            to: frame,
            with: .stringList(["common", targetIndex == 0 ? "first" : "second"]),
            probe: probe
          )
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestCount, 4)
    let report = try fixture.readReport()
    XCTAssertEqual(report.failureCodes, [.multiTargetSharedValueDisagreement])
    XCTAssertEqual(report.targets.count, 2)
  }

  func testToolchainsScalarResponseFailsShapeAndForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 17,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        requestCount += 1
        if requestCount == 1 {
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)),
            probe: probe
          )
        } else {
          XCTAssertEqual(try decodeStringListMacroRequest(frame).macroName, "TOOLCHAINS")
          try respond(to: frame, with: .string("wrong-shape"), probe: probe)
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseShapeMismatch])
  }

  func testMalformedToolchainsResponseFailsDecodeAndForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 21,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        requestCount += 1
        if requestCount == 1 {
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)),
            probe: probe
          )
        } else {
          XCTAssertEqual(try decodeStringListMacroRequest(frame).macroName, "TOOLCHAINS")
          let malformed = BuildServiceRawFrame(
            channel: frame.channel,
            payload: [0xC1],
            messageName: MacroEvaluationResponse.name
          )
          XCTAssertTrue(
            try probe.intercept(
              direction: .serviceToClient,
              frame: malformed,
              send: { _ in }
            )
          )
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseDecodeFailed])
  }

  func testUnexpectedTrafficDuringToolchainsQueryIsConsumedAndFailsProbe() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 18,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        requestCount += 1
        if requestCount == 1 {
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)),
            probe: probe
          )
        } else {
          XCTAssertEqual(try decodeStringListMacroRequest(frame).macroName, "TOOLCHAINS")
          let unexpected = BuildServiceRawFrame(
            channel: frame.channel,
            payload: SwiftBuildProtocolCodec.encode(BoolResponse(true)),
            messageName: BoolResponse.name
          )
          XCTAssertTrue(
            try probe.intercept(
              direction: .serviceToClient,
              frame: unexpected,
              send: { _ in }
            )
          )
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(
      try fixture.readReport().failureCodes,
      [.unexpectedSameChannelTraffic]
    )
  }

  func testToolchainsTimeoutForwardsCreateAndConsumesLateListResponse() throws {
    let fixture = try ProbeFixture(environmentKeys: ["TOOLCHAINS"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe(timeout: 0.001)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 20,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var requestCount = 0
    var listRequestFrame: BuildServiceRawFrame?

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        requestCount += 1
        if requestCount == 1 {
          try respond(
            to: frame,
            with: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys)),
            probe: probe
          )
        } else {
          XCTAssertEqual(try decodeStringListMacroRequest(frame).macroName, "TOOLCHAINS")
          listRequestFrame = frame
        }
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.timeout])
    let lateResponse = BuildServiceRawFrame(
      channel: try XCTUnwrap(listRequestFrame).channel,
      payload: SwiftBuildProtocolCodec.encode(
        MacroEvaluationResponse(result: .stringList(["late-toolchain"]))
      ),
      messageName: MacroEvaluationResponse.name
    )
    XCTAssertTrue(
      try probe.intercept(
        direction: .serviceToClient,
        frame: lateResponse,
        send: { _ in }
      )
    )
    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .serviceToClient,
        channel: original.channel,
        payloadLength: 1,
        messageName: BoolResponse.name
      )
    )
  }

  func testEffectiveTargetParametersAndSharedDisagreementFailProbeButForwardCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: ["HOME"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let targetOverride = makeBuildParameters(action: "install", configuration: "Release")
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil),
        ConfiguredTargetMessagePayload(guid: "TARGET-B", parameters: targetOverride),
      ]
    )
    let original = BuildServiceRawFrame(
      channel: 19,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    let keys = EvaluatedSettingsProbe.fixedPlanRoleKeys + ["HOME"]
    var requestIndex = 0
    var decodedParameters: [BuildParametersMessagePayload] = []

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let macroRequest = try decodeMacroRequest(frame)
        decodedParameters.append(macroRequest.parameters)
        var values = makeValues(
          keys: keys,
          overrides: [
            "BAZEL_LABEL": "label-\(requestIndex)",
            "BAZEL_TARGET_ID": "id-\(requestIndex)",
            "FULL_PRODUCT_NAME": "product-\(requestIndex)",
            "TARGET_BUILD_DIR": "directory-\(requestIndex)",
            "TARGET_NAME": "target-\(requestIndex)",
            "HOME": requestIndex == 0 ? "/first" : "/second",
          ]
        )
        requestIndex += 1
        let response = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(
            MacroEvaluationResponse(result: .stringList(values))
          ),
          messageName: MacroEvaluationResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
        )
        values.removeAll(keepingCapacity: false)
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(decodedParameters, [request.request.parameters, targetOverride])
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .failed)
    XCTAssertEqual(report.failureCodes, [.multiTargetSharedValueDisagreement])
    XCTAssertEqual(report.targetCount, 2)
    XCTAssertEqual(report.targets.count, 2)
  }

  func testPreviewCommandDisagreementFailsProbeAndForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)],
      buildCommand: .preview(style: .xojit)
    )
    let original = BuildServiceRawFrame(
      channel: 23,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    let keys = EvaluatedSettingsProbe.fixedPlanRoleKeys

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let response = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(
            MacroEvaluationResponse(
              result: .stringList(makeValues(keys: keys, overrides: ["ENABLE_PREVIEWS": "NO"]))
            )
          ),
          messageName: MacroEvaluationResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
        )
      }
    )

    XCTAssertFalse(consumed)
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .failed)
    XCTAssertEqual(report.failureCodes, [.previewStateDisagreement])
  }

  func testResponseCountMismatchFailsProbeAndForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 29,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let response = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(
            MacroEvaluationResponse(result: .stringList(["too-short"]))
          ),
          messageName: MacroEvaluationResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
        )
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseCountMismatch])
  }

  func testResponseShapeMismatchFailsProbeAndForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 30,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let response = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(
            MacroEvaluationResponse(result: .string("wrong-shape"))
          ),
          messageName: MacroEvaluationResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
        )
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseShapeMismatch])
  }

  func testTimeoutForwardsCreateAndConsumesLateMatchingResponse() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe(timeout: 0.001)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 31,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var injectedFrame: BuildServiceRawFrame?

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { injectedFrame = $0 }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.timeout])
    let lateResponse = BuildServiceRawFrame(
      channel: try XCTUnwrap(injectedFrame).channel,
      payload: SwiftBuildProtocolCodec.encode(
        MacroEvaluationResponse(
          result: .stringList(makeValues(keys: EvaluatedSettingsProbe.fixedPlanRoleKeys))
        )
      ),
      messageName: MacroEvaluationResponse.name
    )
    XCTAssertTrue(
      probe.shouldIntercept(
        direction: .serviceToClient,
        channel: lateResponse.channel,
        payloadLength: UInt32(lateResponse.payload.count),
        messageName: MacroEvaluationResponse.name
      )
    )
    XCTAssertTrue(
      try probe.intercept(direction: .serviceToClient, frame: lateResponse, send: { _ in })
    )
  }

  func testUnexpectedSameChannelTrafficIsDetectedAndConsumed() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 37,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        let unexpected = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(BoolResponse(true)),
          messageName: BoolResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(direction: .serviceToClient, frame: unexpected, send: { _ in })
        )
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(
      try fixture.readReport().failureCodes,
      [.unexpectedSameChannelTraffic]
    )
  }

  func testTimeoutDrainConsumesExactlyFirstSameChannelFrame() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe(timeout: 0.001)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 41,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    XCTAssertFalse(
      try probe.intercept(direction: .clientToService, frame: original, send: { _ in })
    )
    let lateUnexpected = BuildServiceRawFrame(
      channel: original.channel,
      payload: SwiftBuildProtocolCodec.encode(BoolResponse(false)),
      messageName: BoolResponse.name
    )
    XCTAssertTrue(
      try probe.intercept(
        direction: .serviceToClient,
        frame: lateUnexpected,
        send: { _ in }
      )
    )
    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .serviceToClient,
        channel: original.channel,
        payloadLength: 1,
        messageName: BoolResponse.name
      )
    )
  }

  func testInvalidManifestWritesFailedPrivateReportAndLeavesProbeDisabled() throws {
    let fixture = try ProbeFixture(environmentKeys: [], schemaVersion: 3)
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()

    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .clientToService,
        channel: 1,
        payloadLength: 1,
        messageName: CreateBuildRequest.name
      )
    )
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .failed)
    XCTAssertEqual(report.failureCodes, [.invalidManifest])
  }

  func testExistingReportDestinationIsRejected() throws {
    let fixture = try ProbeFixture(environmentKeys: [], createReport: true)
    defer { fixture.remove() }
    XCTAssertThrowsError(try fixture.makeProbe()) {
      XCTAssertEqual(
        $0 as? EvaluatedSettingsProbeReportWriterError,
        .destinationAlreadyExists
      )
    }
  }

  func testManifestLeafSymlinkFailsClosed() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let symlinkURL = fixture.directoryURL.appendingPathComponent("manifest-link.json")
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: fixture.manifestURL
    )
    let alternateReportURL = fixture.directoryURL.appendingPathComponent("symlink-report.json")
    let probe = try EvaluatedSettingsProbe(
      manifestURL: symlinkURL,
      reportURL: alternateReportURL,
      timeout: 0.1
    )

    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .clientToService,
        channel: 1,
        payloadLength: 1,
        messageName: CreateBuildRequest.name
      )
    )
    let report = try JSONDecoder().decode(
      EvaluatedSettingsProbeReport.self,
      from: Data(contentsOf: alternateReportURL)
    )
    XCTAssertEqual(report.failureCodes, [.invalidManifest])
  }

  func testOversizeManifestFailsClosed() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    try Data(repeating: 0x20, count: 1024 * 1024 + 1).write(to: fixture.manifestURL)
    let alternateReportURL = fixture.directoryURL.appendingPathComponent("oversize-report.json")
    let probe = try EvaluatedSettingsProbe(
      manifestURL: fixture.manifestURL,
      reportURL: alternateReportURL,
      timeout: 0.1
    )

    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .clientToService,
        channel: 1,
        payloadLength: 1,
        messageName: CreateBuildRequest.name
      )
    )
    let report = try JSONDecoder().decode(
      EvaluatedSettingsProbeReport.self,
      from: Data(contentsOf: alternateReportURL)
    )
    XCTAssertEqual(report.failureCodes, [.invalidManifest])
  }
}

private struct DecodedMacroRequest {
  let targetGUID: String
  let parameters: BuildParametersMessagePayload
  let expressions: [String]
}

private struct DecodedStringListMacroRequest {
  let targetGUID: String
  let parameters: BuildParametersMessagePayload
  let macroName: String
}

private func decodeMacroRequest(_ frame: BuildServiceRawFrame) throws -> DecodedMacroRequest {
  let ipcMessage = try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload)
  let request = try XCTUnwrap(ipcMessage.message as? MacroEvaluationRequest)
  guard case .components(let level, let parameters) = request.context,
    case .target(let guid) = level,
    case .stringExpressionArray(let expressions) = request.request
  else {
    throw SwiftBuildProtocolCodecError.unexpectedMacroEvaluationResult
  }
  return DecodedMacroRequest(
    targetGUID: guid,
    parameters: parameters,
    expressions: expressions
  )
}

private func decodeStringListMacroRequest(
  _ frame: BuildServiceRawFrame
) throws -> DecodedStringListMacroRequest {
  let ipcMessage = try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload)
  let request = try XCTUnwrap(ipcMessage.message as? MacroEvaluationRequest)
  guard case .components(let level, let parameters) = request.context,
    case .target(let guid) = level,
    case .macro(let macroName) = request.request,
    request.resultType == .stringList
  else {
    throw SwiftBuildProtocolCodecError.unexpectedMacroEvaluationResult
  }
  return DecodedStringListMacroRequest(
    targetGUID: guid,
    parameters: parameters,
    macroName: macroName
  )
}

private func respond(
  to frame: BuildServiceRawFrame,
  with result: MacroEvaluationResult,
  probe: EvaluatedSettingsProbe
) throws {
  let response = BuildServiceRawFrame(
    channel: frame.channel,
    payload: SwiftBuildProtocolCodec.encode(MacroEvaluationResponse(result: result)),
    messageName: MacroEvaluationResponse.name
  )
  XCTAssertTrue(
    try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
  )
}

private func makeValues(keys: [String], overrides: [String: String] = [:]) -> [String] {
  keys.map { key in
    if let value = overrides[key] { return value }
    if key == "ENABLE_PREVIEWS" { return "NO" }
    return "shared-\(key.lowercased())"
  }
}

private func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private final class ProbeFixture {
  let directoryURL: URL
  let manifestURL: URL
  let reportURL: URL

  init(
    environmentKeys: [String],
    schemaVersion: Int = 2,
    createReport: Bool = false
  ) throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    manifestURL = directoryURL.appendingPathComponent("manifest.json")
    reportURL = directoryURL.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let manifest: [String: Any] = [
      "schemaVersion": schemaVersion,
      "invocation": ["environmentKeys": environmentKeys],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: manifestURL)
    if createReport {
      XCTAssertTrue(FileManager.default.createFile(atPath: reportURL.path, contents: Data()))
    }
  }

  func makeProbe(timeout: TimeInterval = 0.1) throws -> EvaluatedSettingsProbe {
    try EvaluatedSettingsProbe(
      manifestURL: manifestURL,
      reportURL: reportURL,
      timeout: timeout
    )
  }

  func readReport() throws -> EvaluatedSettingsProbeReport {
    try JSONDecoder().decode(
      EvaluatedSettingsProbeReport.self,
      from: Data(contentsOf: reportURL)
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
