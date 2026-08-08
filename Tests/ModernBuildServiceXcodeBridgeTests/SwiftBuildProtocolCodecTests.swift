import CryptoKit
import Foundation
import SWBProtocol
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
    XCTAssertEqual(MacroEvaluationRequest.name, "MACRO_EVALUATION_REQUEST")
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

  func testMacroEvaluationCodecPreservesTargetAndEffectiveParameters() throws {
    let parameters = makeBuildParameters(action: "install", configuration: "Release")
    let expressions = ["$(BAZEL_LABEL)", "$(TARGET_BUILD_DIR)"]

    let payload = SwiftBuildProtocolCodec.encodeMacroEvaluationRequest(
      sessionHandle: "SESSION-1",
      targetGUID: "TARGET-B",
      buildParameters: parameters,
      expressions: expressions
    )
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)
    let request = try XCTUnwrap(message.message as? MacroEvaluationRequest)
    guard case .components(let level, let decodedParameters) = request.context else {
      return XCTFail("Expected component-scoped macro evaluation")
    }
    guard case .target(let guid) = level else {
      return XCTFail("Expected target-scoped macro evaluation")
    }
    guard case .stringExpressionArray(let decodedExpressions) = request.request else {
      return XCTFail("Expected one expression-array request")
    }

    XCTAssertEqual(request.sessionHandle, "SESSION-1")
    XCTAssertEqual(guid, "TARGET-B")
    XCTAssertEqual(decodedParameters, parameters)
    XCTAssertEqual(decodedExpressions, expressions)
    XCTAssertNil(request.overrides)
    XCTAssertEqual(request.resultType, .stringList)
  }

  func testStringListMacroCodecPreservesTypeAndEffectiveParameters() throws {
    let parameters = makeBuildParameters(action: "install", configuration: "Release")

    let payload = SwiftBuildProtocolCodec.encodeStringListMacroEvaluationRequest(
      sessionHandle: "SESSION-1",
      targetGUID: "TARGET-B",
      buildParameters: parameters,
      macroName: "TOOLCHAINS"
    )
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(payload)
    let request = try XCTUnwrap(message.message as? MacroEvaluationRequest)
    guard case .components(let level, let decodedParameters) = request.context else {
      return XCTFail("Expected component-scoped macro evaluation")
    }
    guard case .target(let guid) = level else {
      return XCTFail("Expected target-scoped macro evaluation")
    }
    guard case .macro(let macroName) = request.request else {
      return XCTFail("Expected a declared macro request")
    }

    XCTAssertEqual(request.sessionHandle, "SESSION-1")
    XCTAssertEqual(guid, "TARGET-B")
    XCTAssertEqual(decodedParameters, parameters)
    XCTAssertEqual(macroName, "TOOLCHAINS")
    XCTAssertNil(request.overrides)
    XCTAssertEqual(request.resultType, .stringList)
  }

  func testAcceptedXcode17F42MacroEvaluationCompatibilityFixtures() throws {
    let requestBase64 =
      "uE1BQ1JPX0VWQUxVQVRJT05fUkVRVUVTVMUBjHsiY29udGV4dCI6eyJjb21wb25lbnRzIjp7ImJ1aWxkUGFyYW1ldGVycyI6eyJhY3Rpb24iOiJpbnN0YWxsIiwiYWN0aXZlQXJjaGl0ZWN0dXJlIjoiYXJtNjQiLCJjb25maWd1cmF0aW9uIjoiUmVsZWFzZSIsIm92ZXJyaWRlcyI6eyJjb21tYW5kTGluZSI6e30sImNvbW1hbmRMaW5lQ29uZmlnIjp7fSwiZW52aXJvbm1lbnRDb25maWciOnt9LCJzeW50aGVzaXplZCI6e319fSwibGV2ZWwiOnsidGFyZ2V0Ijp7Il8wIjoiVEFSR0VULUIifX19fSwicmVxdWVzdCI6eyJzdHJpbmdFeHByZXNzaW9uQXJyYXkiOnsiXzAiOlsiJChCQVpFTF9MQUJFTCkiLCIkKFRBUkdFVF9CVUlMRF9ESVIpIl19fSwicmVzdWx0VHlwZSI6eyJzdHJpbmdMaXN0Ijp7fX0sInNlc3Npb25IYW5kbGUiOiJTRVNTSU9OLTEifQ=="
    let listMacroRequestBase64 =
      "uE1BQ1JPX0VWQUxVQVRJT05fUkVRVUVTVMUBYHsiY29udGV4dCI6eyJjb21wb25lbnRzIjp7ImJ1aWxkUGFyYW1ldGVycyI6eyJhY3Rpb24iOiJpbnN0YWxsIiwiYWN0aXZlQXJjaGl0ZWN0dXJlIjoiYXJtNjQiLCJjb25maWd1cmF0aW9uIjoiUmVsZWFzZSIsIm92ZXJyaWRlcyI6eyJjb21tYW5kTGluZSI6e30sImNvbW1hbmRMaW5lQ29uZmlnIjp7fSwiZW52aXJvbm1lbnRDb25maWciOnt9LCJzeW50aGVzaXplZCI6e319fSwibGV2ZWwiOnsidGFyZ2V0Ijp7Il8wIjoiVEFSR0VULUIifX19fSwicmVxdWVzdCI6eyJtYWNybyI6eyJfMCI6IlRPT0xDSEFJTlMifX0sInJlc3VsdFR5cGUiOnsic3RyaW5nTGlzdCI6e319LCJzZXNzaW9uSGFuZGxlIjoiU0VTU0lPTi0xIn0="
    let responseBase64 =
      "uU1BQ1JPX0VWQUxVQVRJT05fUkVTUE9OU0XENnsicmVzdWx0Ijp7InN0cmluZ0xpc3QiOnsiXzAiOlsidmFsdWUtYSIsInZhbHVlLWIiXX19fQ=="
    let requestFixture = try XCTUnwrap(Data(base64Encoded: requestBase64))
    let listMacroRequestFixture = try XCTUnwrap(Data(base64Encoded: listMacroRequestBase64))
    let responseFixture = try XCTUnwrap(Data(base64Encoded: responseBase64))

    XCTAssertEqual(
      sha256(requestFixture), "7c2c88341544b80107da035a84ef97fe59ff8e5765ee1a44086e5a92c2d51eb1")
    XCTAssertEqual(
      sha256(responseFixture),
      "9c6b0271fedc02b7b9be33a3af9595b2112316cb17296d345f5fe914bd67ef00")
    XCTAssertEqual(
      sha256(listMacroRequestFixture),
      "12ade669bd0efcd35dfd73b31c6e0d756121a75c1e2fdc98286cba2e26e5f5a6")

    let requestIPC = try SwiftBuildProtocolCodec.decodeIPCMessage(Array(requestFixture))
    let request = try XCTUnwrap(requestIPC.message as? MacroEvaluationRequest)
    guard case .components(let level, let parameters) = request.context,
      case .target(let targetGUID) = level,
      case .stringExpressionArray(let expressions) = request.request
    else {
      return XCTFail("Expected target-scoped expression-array fixture")
    }
    XCTAssertEqual(request.sessionHandle, "SESSION-1")
    XCTAssertEqual(targetGUID, "TARGET-B")
    XCTAssertEqual(parameters.action, "install")
    XCTAssertEqual(parameters.configuration, "Release")
    XCTAssertEqual(expressions, ["$(BAZEL_LABEL)", "$(TARGET_BUILD_DIR)"])
    XCTAssertEqual(SwiftBuildProtocolCodec.encode(request), Array(requestFixture))

    let listRequestIPC = try SwiftBuildProtocolCodec.decodeIPCMessage(
      Array(listMacroRequestFixture)
    )
    let listRequest = try XCTUnwrap(listRequestIPC.message as? MacroEvaluationRequest)
    guard case .macro(let listMacroName) = listRequest.request else {
      return XCTFail("Expected declared list-macro fixture")
    }
    XCTAssertEqual(listMacroName, "TOOLCHAINS")
    XCTAssertEqual(listRequest.resultType, .stringList)
    XCTAssertEqual(
      SwiftBuildProtocolCodec.encode(listRequest),
      Array(listMacroRequestFixture)
    )

    let values = try SwiftBuildProtocolCodec.decodeMacroEvaluationResponse(
      Array(responseFixture)
    )
    XCTAssertEqual(values, ["value-a", "value-b"])
    XCTAssertEqual(
      SwiftBuildProtocolCodec.encode(
        MacroEvaluationResponse(result: .stringList(values))
      ),
      Array(responseFixture)
    )
  }

  func testMacroEvaluationResponseRejectsNonListShape() {
    let payload = SwiftBuildProtocolCodec.encode(
      MacroEvaluationResponse(result: .string("wrong-shape"))
    )

    XCTAssertThrowsError(try SwiftBuildProtocolCodec.decodeMacroEvaluationResponse(payload)) {
      XCTAssertEqual(
        $0 as? SwiftBuildProtocolCodecError,
        .unexpectedMacroEvaluationResult
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
  parameters: BuildParametersMessagePayload = makeBuildParameters()
) -> CreateBuildRequest {
  CreateBuildRequest(
    sessionHandle: "SESSION-1",
    responseChannel: 91,
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
      containerPath: nil,
      buildDescriptionID: nil,
      qos: .userInitiated,
      schedulerLaneWidthOverride: nil,
      jsonRepresentation: nil
    ),
    onlyCreateBuildDescription: false,
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
