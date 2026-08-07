import CryptoKit
import Foundation
import SWBProtocol
import SWBUtil
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class SwiftBuildProtocolCodecTests: XCTestCase {
  func testPinnedPublicProductsEncodeAndDecodeCreateBuild() throws {
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "TARGET-A", parameters: nil)]
    )

    let payload = SwiftBuildProtocolCodec.encode(request)
    let decoded = try SwiftBuildProtocolCodec.decodeCreateBuild(payload)

    XCTAssertEqual(CreateBuildRequest.name, "CREATE_BUILD")
    XCTAssertEqual(
      AllExportedMacrosAndValuesRequest.name,
      "ALL_EXPORTED_MACROS_AND_VALUES_REQUEST"
    )
    XCTAssertEqual(decoded, request)
  }

  func testAcceptedXcode17F42CreateBuildCompatibilityFixture() throws {
    let fixtureBase64 =
      "rENSRUFURV9CVUlMRMUCx3sib25seUNyZWF0ZUJ1aWxkRGVzY3JpcHRpb24iOmZhbHNlLCJyZXF1ZXN0Ijp7ImJ1aWxkQ29tbWFuZCI6eyJjb21tYW5kIjoiYnVpbGQiLCJza2lwRGVwZW5kZW5jaWVzIjpmYWxzZSwic3R5bGUiOjB9LCJjb25maWd1cmVkVGFyZ2V0cyI6W3siZ3VpZCI6IlRBUkdFVC1BIn1dLCJjb250aW51ZUJ1aWxkaW5nQWZ0ZXJFcnJvcnMiOmZhbHNlLCJkZXBlbmRlbmN5U2NvcGUiOjAsImdlbmVyYXRlUHJlY29tcGlsZWRNb2R1bGVzUmVwb3J0IjpmYWxzZSwiaGlkZVNoZWxsU2NyaXB0RW52aXJvbm1lbnQiOnRydWUsInBhcmFtZXRlcnMiOnsiYWN0aW9uIjoiYnVpbGQiLCJhY3RpdmVBcmNoaXRlY3R1cmUiOiJhcm02NCIsImNvbmZpZ3VyYXRpb24iOiJEZWJ1ZyIsIm92ZXJyaWRlcyI6eyJjb21tYW5kTGluZSI6e30sImNvbW1hbmRMaW5lQ29uZmlnIjp7fSwiZW52aXJvbm1lbnRDb25maWciOnt9LCJzeW50aGVzaXplZCI6e319fSwicW9zIjozLCJyZWNvcmRCdWlsZEJhY2t0cmFjZXMiOmZhbHNlLCJzY2hlbWVDb21tYW5kIjowLCJzaG93Tm9uTG9nZ2VkUHJvZ3Jlc3MiOnRydWUsInVzZURyeVJ1biI6ZmFsc2UsInVzZUltcGxpY2l0RGVwZW5kZW5jaWVzIjpmYWxzZSwidXNlUGFyYWxsZWxUYXJnZXRzIjp0cnVlfSwicmVzcG9uc2VDaGFubmVsIjo5MSwicmV0YWluQnVpbGREZXNjcmlwdGlvbiI6ZmFsc2UsInNlc3Npb25IYW5kbGUiOiJTRVNTSU9OLTEifQ=="
    let fixture = try XCTUnwrap(Data(base64Encoded: fixtureBase64))

    XCTAssertEqual(SwiftBuildProtocolCompatibility.xcodeProductBuildVersion, "17F42")
    XCTAssertEqual(
      SwiftBuildProtocolCompatibility.swiftBuildCommit,
      "e4f6fc77ebe727657dadfedf50462f5a1a626ead"
    )
    XCTAssertEqual(
      sha256(fixture), "a950811e436c263b67aa5f983ae36efc84c000bd352010a46200b5571b7774e2")

    let decoded = try SwiftBuildProtocolCodec.decodeCreateBuild(Array(fixture))
    XCTAssertEqual(decoded.sessionHandle, "SESSION-1")
    XCTAssertEqual(decoded.responseChannel, 91)
    XCTAssertEqual(decoded.request.configuredTargets.map(\.guid), ["TARGET-A"])
    XCTAssertEqual(SwiftBuildProtocolCodec.encode(decoded), Array(fixture))
  }

  func testExportedSettingsRequestPreservesTargetAndEffectiveParameters() throws {
    let parameters = makeBuildParameters(action: "install", configuration: "Release")

    let payload = SwiftBuildProtocolCodec.encodeAllExportedMacrosAndValuesRequest(
      sessionHandle: "SESSION-1",
      targetGUID: "TARGET-B",
      buildParameters: parameters
    )
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)
    let request = try XCTUnwrap(message.message as? AllExportedMacrosAndValuesRequest)
    guard case .components(let level, let decodedParameters) = request.context else {
      return XCTFail("Expected component-scoped exported-settings request")
    }
    guard case .target(let guid) = level else {
      return XCTFail("Expected target-scoped exported-settings request")
    }

    XCTAssertEqual(request.sessionHandle, "SESSION-1")
    XCTAssertEqual(guid, "TARGET-B")
    XCTAssertEqual(decodedParameters, parameters)
  }

  func testPinnedSwiftBuildExportedSettingsCompatibilityFixtures() throws {
    // These fixtures are rendered from the public request/response products at
    // Swift Build e4f6fc77, not captured from a private Xcode implementation.
    let requestBase64 =
      "2SZBTExfRVhQT1JURURfTUFDUk9TX0FORF9WQUxVRVNfUkVRVUVTVMUBGXsiY29udGV4dCI6eyJjb21wb25lbnRzIjp7ImJ1aWxkUGFyYW1ldGVycyI6eyJhY3Rpb24iOiJpbnN0YWxsIiwiYWN0aXZlQXJjaGl0ZWN0dXJlIjoiYXJtNjQiLCJjb25maWd1cmF0aW9uIjoiUmVsZWFzZSIsIm92ZXJyaWRlcyI6eyJjb21tYW5kTGluZSI6e30sImNvbW1hbmRMaW5lQ29uZmlnIjp7fSwiZW52aXJvbm1lbnRDb25maWciOnt9LCJzeW50aGVzaXplZCI6e319fSwibGV2ZWwiOnsidGFyZ2V0Ijp7Il8wIjoiVEFSR0VULUIifX19fSwic2Vzc2lvbkhhbmRsZSI6IlNFU1NJT04tMSJ9"
    let responseBase64 =
      "2SdBTExfRVhQT1JURURfTUFDUk9TX0FORF9WQUxVRVNfUkVTUE9OU0XEVHsicmVzdWx0Ijp7IkJBWkVMX0xBQkVMIjoibGFiZWwiLCJUT09MQ0hBSU5TIjoibWV0YWwgZGVmYXVsdCIsIlVOUkVMQVRFRCI6InNlY3JldCJ9fQ=="
    let requestFixture = try XCTUnwrap(Data(base64Encoded: requestBase64))
    let responseFixture = try XCTUnwrap(Data(base64Encoded: responseBase64))

    XCTAssertEqual(requestFixture.count, 324)
    XCTAssertEqual(
      sha256(requestFixture), "28487bfc977efd427c2460e04c2699bba9e62d92179c0ed6ef290e5583054d4b")
    XCTAssertEqual(responseFixture.count, 127)
    XCTAssertEqual(
      sha256(responseFixture), "e682c9c02dca4e1a34b03034a56e6a160fc348c6765c2628282073c61f2f0656")

    let requestMessage = try SwiftBuildProtocolCodec.decodeIPCMessage(Array(requestFixture))
    let request = try XCTUnwrap(requestMessage.message as? AllExportedMacrosAndValuesRequest)
    guard case .components(let level, let parameters) = request.context else {
      return XCTFail("Expected component-scoped exported-settings fixture")
    }
    guard case .target(let guid) = level else {
      return XCTFail("Expected target-scoped exported-settings fixture")
    }
    XCTAssertEqual(request.sessionHandle, "SESSION-1")
    XCTAssertEqual(guid, "TARGET-B")
    XCTAssertEqual(parameters.action, "install")
    XCTAssertEqual(parameters.configuration, "Release")
    XCTAssertEqual(SwiftBuildProtocolCodec.encode(request), Array(requestFixture))

    let selected = try SwiftBuildProtocolCodec.decodeAllExportedMacrosAndValuesResponse(
      Array(responseFixture),
      selecting: ["BAZEL_LABEL", "TOOLCHAINS", "MISSING"]
    )
    XCTAssertEqual(selected, ["label", "metal default", ""])
    XCTAssertFalse(selected.contains("secret"))

    let responseMessage = try SwiftBuildProtocolCodec.decodeIPCMessage(Array(responseFixture))
    let response = try XCTUnwrap(responseMessage.message as? AllExportedMacrosAndValuesResponse)
    XCTAssertEqual(SwiftBuildProtocolCodec.encode(response), Array(responseFixture))
  }

  func testExportedSettingsResponseProjectsAllowlistAndRepresentsMissingAsEmpty() throws {
    let payload = SwiftBuildProtocolCodec.encode(
      AllExportedMacrosAndValuesResponse(
        result: [
          "REQUESTED": "requested-value",
          "UNRELATED_SECRET": "must-not-cross-boundary",
        ]
      )
    )

    let selected = try SwiftBuildProtocolCodec.decodeAllExportedMacrosAndValuesResponse(
      payload,
      selecting: ["REQUESTED", "MISSING"]
    )

    XCTAssertEqual(selected, ["requested-value", ""])
    XCTAssertFalse(selected.contains("must-not-cross-boundary"))
  }

  func testExportedSettingsResponseRejectsWrongMessageShape() {
    let payload = SwiftBuildProtocolCodec.encode(BoolResponse(true))

    XCTAssertThrowsError(
      try SwiftBuildProtocolCodec.decodeAllExportedMacrosAndValuesResponse(
        payload,
        selecting: ["REQUESTED"]
      )
    ) {
      XCTAssertEqual(
        $0 as? SwiftBuildProtocolCodecError,
        .unexpectedMessage(
          expected: AllExportedMacrosAndValuesResponse.name,
          actual: BoolResponse.name
        )
      )
    }
  }
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func makeCreateBuildRequest(
  targets: [ConfiguredTargetMessagePayload],
  buildCommand: BuildCommandMessagePayload = .build(style: .buildOnly, skipDependencies: false),
  parameters: BuildParametersMessagePayload = makeBuildParameters(),
  responseChannel: UInt64 = 91,
  containerPath: Path? = nil,
  onlyCreateBuildDescription: Bool = false
) -> CreateBuildRequest {
  CreateBuildRequest(
    sessionHandle: "SESSION-1",
    responseChannel: responseChannel,
    request: BuildRequestMessagePayload(
      parameters: parameters,
      configuredTargets: targets,
      dependencyScope: .workspace,
      continueBuildingAfterErrors: false,
      hideShellScriptEnvironment: true,
      useParallelTargets: true,
      useImplicitDependencies: false,
      useDryRun: false,
      showNonLoggedProgress: true,
      recordBuildBacktraces: false,
      generatePrecompiledModulesReport: false,
      buildPlanDiagnosticsDirPath: nil,
      buildCommand: buildCommand,
      schemeCommand: .launch,
      containerPath: containerPath,
      buildDescriptionID: nil,
      qos: .userInitiated,
      schedulerLaneWidthOverride: nil,
      jsonRepresentation: nil
    ),
    onlyCreateBuildDescription: onlyCreateBuildDescription,
    retainBuildDescription: false
  )
}

func makeBuildParameters(
  action: String = "build",
  configuration: String = "Debug"
) -> BuildParametersMessagePayload {
  BuildParametersMessagePayload(
    action: action,
    configuration: configuration,
    activeRunDestination: nil,
    activeArchitecture: "arm64",
    arenaInfo: nil,
    overrides: SettingsOverridesMessagePayload(
      synthesized: [:],
      commandLine: [:],
      commandLineConfigPath: nil,
      commandLineConfig: [:],
      environmentConfigPath: nil,
      environmentConfig: [:],
      toolchainOverride: nil
    )
  )
}
