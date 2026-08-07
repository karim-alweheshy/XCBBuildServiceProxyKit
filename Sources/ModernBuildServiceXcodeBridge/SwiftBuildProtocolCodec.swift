import SWBProtocol
import SWBUtil

public enum SwiftBuildProtocolCompatibility {
  public static let xcodeProductBuildVersion = "17F42"
  public static let swiftBuildCommit = "e4f6fc77ebe727657dadfedf50462f5a1a626ead"
}

enum SwiftBuildProtocolCodecError: Error, Equatable {
  case unexpectedMessage(expected: String, actual: String)
  case unexpectedMacroEvaluationResult
}

enum SwiftBuildProtocolCodec {
  static func decodeCreateBuild(_ payload: [UInt8]) throws -> CreateBuildRequest {
    let message = try decodeIPCMessage(payload)
    guard let request = message.message as? CreateBuildRequest else {
      throw SwiftBuildProtocolCodecError.unexpectedMessage(
        expected: CreateBuildRequest.name,
        actual: type(of: message.message).name
      )
    }
    return request
  }

  static func encodeMacroEvaluationRequest(
    sessionHandle: String,
    targetGUID: String,
    buildParameters: BuildParametersMessagePayload,
    expressions: [String]
  ) -> [UInt8] {
    encode(
      MacroEvaluationRequest(
        sessionHandle: sessionHandle,
        context: .components(level: .target(targetGUID), buildParameters: buildParameters),
        request: .stringExpressionArray(expressions),
        overrides: nil,
        resultType: .stringList
      )
    )
  }

  static func decodeMacroEvaluationResponse(_ payload: [UInt8]) throws -> [String] {
    let message = try decodeIPCMessage(payload)
    guard let response = message.message as? MacroEvaluationResponse else {
      throw SwiftBuildProtocolCodecError.unexpectedMessage(
        expected: MacroEvaluationResponse.name,
        actual: type(of: message.message).name
      )
    }
    guard case .stringList(let values) = response.result else {
      throw SwiftBuildProtocolCodecError.unexpectedMacroEvaluationResult
    }
    return values
  }

  static func encode(_ message: any Message) -> [UInt8] {
    let serializer = MsgPackSerializer()
    IPCMessage(message).serialize(to: serializer)
    return serializer.byteString.bytes
  }

  static func decodeIPCMessage(_ payload: [UInt8]) throws -> IPCMessage {
    try IPCMessage(from: MsgPackDeserializer(payload[...]))
  }
}
