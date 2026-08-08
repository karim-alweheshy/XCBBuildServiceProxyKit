import SWBProtocol
import SWBUtil

public enum SwiftBuildProtocolCompatibility {
  public static let xcodeProductBuildVersion = "17F42"
  public static let swiftBuildCommit = "e4f6fc77ebe727657dadfedf50462f5a1a626ead"
}

enum SwiftBuildProtocolCodecError: Error, Equatable {
  case unexpectedMessage(expected: String, actual: String)
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

  static func encodeAllExportedMacrosAndValuesRequest(
    sessionHandle: String,
    targetGUID: String,
    buildParameters: BuildParametersMessagePayload
  ) -> [UInt8] {
    encode(
      AllExportedMacrosAndValuesRequest(
        sessionHandle: sessionHandle,
        context: .components(level: .target(targetGUID), buildParameters: buildParameters)
      )
    )
  }

  static func decodeAllExportedMacrosAndValuesResponse(
    _ payload: [UInt8],
    selecting keys: [String]
  ) throws -> [String] {
    let message = try decodeIPCMessage(payload)
    guard let response = message.message as? AllExportedMacrosAndValuesResponse else {
      throw SwiftBuildProtocolCodecError.unexpectedMessage(
        expected: AllExportedMacrosAndValuesResponse.name,
        actual: type(of: message.message).name
      )
    }
    // Project immediately onto the allowlist so the complete shell environment
    // cannot escape the protocol query boundary.
    return keys.map { response.result[$0] ?? "" }
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
