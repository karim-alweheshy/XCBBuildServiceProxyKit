import CryptoKit
import Foundation
import ModernBuildServiceProxyCore
import SWBProtocol
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class EvaluatedSettingsProbeTests: XCTestCase {
  func testProbeUsesOneExportedSettingsRequestAndForwardsOriginalAfterRedactedSuccess() throws {
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
    let secretValue = "private-value"
    let unknownValue = "unrelated-private-value"

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        serviceBoundFrames.append(frame)
        let exportedRequest = try decodeExportedSettingsRequest(frame)
        XCTAssertNotEqual(frame.channel, original.channel)
        XCTAssertNotEqual(frame.channel, request.responseChannel)
        XCTAssertGreaterThanOrEqual(frame.channel, UInt64(1) << 63)
        XCTAssertEqual(exportedRequest.targetGUID, "TARGET-A")
        XCTAssertEqual(exportedRequest.parameters, request.request.parameters)
        var environment = makeExportedEnvironment(
          overrides: [
            "CUSTOM_SECRET": secretValue,
            "HOME": "/private/home",
          ]
        )
        environment["UNRELATED_SECRET"] = unknownValue
        try respond(to: frame, with: environment, probe: probe)
        environment.removeAll(keepingCapacity: false)
      }
    )
    XCTAssertFalse(consumed)
    serviceBoundFrames.append(original)

    XCTAssertEqual(serviceBoundFrames.count, 2)
    XCTAssertNotEqual(serviceBoundFrames[0].channel, original.channel)
    XCTAssertEqual(serviceBoundFrames[1], original)

    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .succeeded)
    XCTAssertEqual(report.failureCodes, [])
    XCTAssertEqual(report.targetCount, 1)
    XCTAssertEqual(report.targets.count, 1)
    XCTAssertEqual(
      report.targets[0].settings.map(\.key),
      EvaluatedSettingsProbe.fixedPlanRoleKeys + ["CUSTOM_SECRET", "HOME"]
    )
    XCTAssertFalse(report.targets[0].settings.contains { $0.key == "UNRELATED_SECRET" })
    let secretMetadata = try XCTUnwrap(
      report.targets[0].settings.first { $0.key == "CUSTOM_SECRET" }
    )
    XCTAssertTrue(secretMetadata.present)
    XCTAssertEqual(secretMetadata.valueByteLength, secretValue.utf8.count)
    XCTAssertEqual(secretMetadata.valueSHA256, sha256(secretValue))

    let reportText = try String(contentsOf: fixture.reportURL, encoding: .utf8)
    XCTAssertFalse(reportText.contains(secretValue))
    XCTAssertFalse(reportText.contains(unknownValue))
    XCTAssertFalse(reportText.contains("SESSION-1"))
    XCTAssertFalse(reportText.contains("TARGET-A"))
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.reportURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    XCTAssertEqual(permissions & 0o777, 0o600)
  }

  func testMissingOptionalManifestEnvironmentIsRepresentedAsAbsent() throws {
    let fixture = try ProbeFixture(environmentKeys: ["OPTIONAL_MISSING"])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 15,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    XCTAssertFalse(
      try probe.intercept(
        direction: .clientToService,
        frame: original,
        send: { frame in
          try respond(to: frame, with: makeExportedEnvironment(), probe: probe)
        }
      )
    )

    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .succeeded)
    let metadata = try XCTUnwrap(
      report.targets[0].settings.first { $0.key == "OPTIONAL_MISSING" }
    )
    XCTAssertFalse(metadata.present)
    XCTAssertEqual(metadata.valueByteLength, 0)
    XCTAssertEqual(metadata.valueSHA256, sha256(""))
  }

  func testMissingRequiredPlanRoleFailsProbeButForwardsCreate() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )
    let original = BuildServiceRawFrame(
      channel: 16,
      payload: SwiftBuildProtocolCodec.encode(request)
    )

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        try respond(
          to: frame,
          with: makeExportedEnvironment(omitting: ["BAZEL_OUT"]),
          probe: probe
        )
      }
    )

    XCTAssertFalse(consumed)
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .failed)
    XCTAssertEqual(report.failureCodes, [.missingRequiredPlanRole])
    let metadata = try XCTUnwrap(
      report.targets[0].settings.first { $0.key == "BAZEL_OUT" }
    )
    XCTAssertFalse(metadata.present)
    XCTAssertEqual(metadata.valueByteLength, 0)
    XCTAssertEqual(metadata.valueSHA256, sha256(""))
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
    var requestIndex = 0
    var decodedParameters: [BuildParametersMessagePayload] = []
    var auxiliaryChannels: [UInt64] = []

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        auxiliaryChannels.append(frame.channel)
        let exportedRequest = try decodeExportedSettingsRequest(frame)
        decodedParameters.append(exportedRequest.parameters)
        let environment = makeExportedEnvironment(
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
        try respond(to: frame, with: environment, probe: probe)
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(requestIndex, 2)
    XCTAssertEqual(Set(auxiliaryChannels).count, 2)
    XCTAssertFalse(auxiliaryChannels.contains(original.channel))
    XCTAssertFalse(auxiliaryChannels.contains(request.responseChannel))
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

    let consumed = try probe.intercept(
      direction: .clientToService,
      frame: original,
      send: { frame in
        try respond(
          to: frame,
          with: makeExportedEnvironment(overrides: ["ENABLE_PREVIEWS": "NO"]),
          probe: probe
        )
      }
    )

    XCTAssertFalse(consumed)
    let report = try fixture.readReport()
    XCTAssertEqual(report.status, .failed)
    XCTAssertEqual(report.failureCodes, [.previewStateDisagreement])
  }

  func testMalformedExportedSettingsResponseFailsProbeAndForwardsCreate() throws {
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
        let malformed = BuildServiceRawFrame(
          channel: frame.channel,
          payload: [0xC1],
          messageName: AllExportedMacrosAndValuesResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(
            direction: .serviceToClient,
            frame: malformed,
            send: { _ in }
          )
        )
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseDecodeFailed])
  }

  func testServiceErrorResponseFailsShapeAndForwardsCreate() throws {
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
        let errorResponse = BuildServiceRawFrame(
          channel: frame.channel,
          payload: SwiftBuildProtocolCodec.encode(ErrorResponse("synthetic-error")),
          messageName: ErrorResponse.name
        )
        XCTAssertTrue(
          try probe.intercept(
            direction: .serviceToClient,
            frame: errorResponse,
            send: { _ in }
          )
        )
      }
    )

    XCTAssertFalse(consumed)
    XCTAssertEqual(try fixture.readReport().failureCodes, [.responseShapeMismatch])
    let reportText = try String(contentsOf: fixture.reportURL, encoding: .utf8)
    XCTAssertFalse(reportText.contains("synthetic-error"))
  }

  func testTimeoutForwardsCreateAndDoesNotConsumeNativeBuildCreated() throws {
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
    let auxiliaryFrame = try XCTUnwrap(injectedFrame)
    XCTAssertNotEqual(auxiliaryFrame.channel, original.channel)

    let buildCreated = BuildServiceRawFrame(
      channel: original.channel,
      payload: SwiftBuildProtocolCodec.encode(BuildCreated(id: 1)),
      messageName: BuildCreated.name
    )
    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .serviceToClient,
        channel: buildCreated.channel,
        payloadLength: UInt32(buildCreated.payload.count),
        messageName: buildCreated.messageName
      )
    )
    XCTAssertFalse(
      try probe.intercept(direction: .serviceToClient, frame: buildCreated, send: { _ in })
    )

    let lateResponse = BuildServiceRawFrame(
      channel: auxiliaryFrame.channel,
      payload: SwiftBuildProtocolCodec.encode(
        AllExportedMacrosAndValuesResponse(result: makeExportedEnvironment())
      ),
      messageName: AllExportedMacrosAndValuesResponse.name
    )
    XCTAssertTrue(
      probe.shouldIntercept(
        direction: .serviceToClient,
        channel: lateResponse.channel,
        payloadLength: UInt32(lateResponse.payload.count),
        messageName: AllExportedMacrosAndValuesResponse.name
      )
    )
    XCTAssertTrue(
      try probe.intercept(direction: .serviceToClient, frame: lateResponse, send: { _ in })
    )
  }

  func testUnexpectedSameChannelTrafficIsDetectedConsumedAndRedacted() throws {
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

    var auxiliaryFrame: BuildServiceRawFrame?
    XCTAssertFalse(
      try probe.intercept(
        direction: .clientToService,
        frame: original,
        send: { auxiliaryFrame = $0 }
      )
    )
    let auxiliaryChannel = try XCTUnwrap(auxiliaryFrame).channel
    let lateUnexpected = BuildServiceRawFrame(
      channel: auxiliaryChannel,
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
        channel: auxiliaryChannel,
        payloadLength: 1,
        messageName: BoolResponse.name
      )
    )
  }

  func testAuxiliaryChannelSkipsObservedRequestAndResponseChannels() throws {
    let fixture = try ProbeFixture(environmentKeys: [])
    defer { fixture.remove() }
    let probe = try fixture.makeProbe()
    let observedChannel = UInt64.max
    let responseChannel = UInt64.max - 1
    let requestChannel = UInt64.max - 2

    XCTAssertFalse(
      probe.shouldIntercept(
        direction: .clientToService,
        channel: observedChannel,
        payloadLength: 1,
        messageName: "PING"
      )
    )
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)],
      responseChannel: responseChannel
    )
    let original = BuildServiceRawFrame(
      channel: requestChannel,
      payload: SwiftBuildProtocolCodec.encode(request)
    )
    var auxiliaryChannel: UInt64?

    XCTAssertFalse(
      try probe.intercept(
        direction: .clientToService,
        frame: original,
        send: { frame in
          auxiliaryChannel = frame.channel
          try respond(to: frame, with: makeExportedEnvironment(), probe: probe)
        }
      )
    )

    XCTAssertEqual(auxiliaryChannel, UInt64.max - 3)
    XCTAssertNotEqual(auxiliaryChannel, observedChannel)
    XCTAssertNotEqual(auxiliaryChannel, responseChannel)
    XCTAssertNotEqual(auxiliaryChannel, requestChannel)
    XCTAssertEqual(try fixture.readReport().status, .succeeded)
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

private struct DecodedExportedSettingsRequest {
  let targetGUID: String
  let parameters: BuildParametersMessagePayload
}

private func decodeExportedSettingsRequest(
  _ frame: BuildServiceRawFrame
) throws -> DecodedExportedSettingsRequest {
  let ipcMessage = try SwiftBuildProtocolCodec.decodeIPCMessage(frame.payload)
  let request = try XCTUnwrap(
    ipcMessage.message as? AllExportedMacrosAndValuesRequest
  )
  guard case .components(let level, let parameters) = request.context,
    case .target(let guid) = level
  else {
    throw SwiftBuildProtocolCodecError.unexpectedMessage(
      expected: AllExportedMacrosAndValuesRequest.name,
      actual: type(of: ipcMessage.message).name
    )
  }
  return DecodedExportedSettingsRequest(
    targetGUID: guid,
    parameters: parameters
  )
}

private func respond(
  to frame: BuildServiceRawFrame,
  with environment: [String: String],
  probe: EvaluatedSettingsProbe
) throws {
  let response = BuildServiceRawFrame(
    channel: frame.channel,
    payload: SwiftBuildProtocolCodec.encode(
      AllExportedMacrosAndValuesResponse(result: environment)
    ),
    messageName: AllExportedMacrosAndValuesResponse.name
  )
  XCTAssertTrue(
    try probe.intercept(direction: .serviceToClient, frame: response, send: { _ in })
  )
}

private func makeExportedEnvironment(
  overrides: [String: String] = [:],
  omitting omittedKeys: Set<String> = []
) -> [String: String] {
  var environment = Dictionary(
    uniqueKeysWithValues: EvaluatedSettingsProbe.fixedPlanRoleKeys.map { key in
      (key, key == "ENABLE_PREVIEWS" ? "NO" : "value-\(key.lowercased())")
    }
  )
  for (key, value) in overrides {
    environment[key] = value
  }
  for key in omittedKeys {
    environment.removeValue(forKey: key)
  }
  return environment
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
