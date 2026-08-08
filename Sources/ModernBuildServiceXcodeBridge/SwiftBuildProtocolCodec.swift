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
    try decode(payload, as: CreateBuildRequest.self)
  }

  static func decodeBuildStart(_ payload: [UInt8]) throws -> BuildStartRequest {
    try decode(payload, as: BuildStartRequest.self)
  }

  static func decodeBuildCancel(_ payload: [UInt8]) throws -> BuildCancelRequest {
    try decode(payload, as: BuildCancelRequest.self)
  }

  static func decodeDeleteSession(_ payload: [UInt8]) throws -> DeleteSessionRequest {
    try decode(payload, as: DeleteSessionRequest.self)
  }

  static func decodeBuildCreated(_ payload: [UInt8]) throws -> BuildCreated {
    try decode(payload, as: BuildCreated.self)
  }

  static func decodeErrorResponse(_ payload: [UInt8]) throws -> ErrorResponse {
    try decode(payload, as: ErrorResponse.self)
  }

  static func decodeBuildOperationEnded(_ payload: [UInt8]) throws
    -> BuildOperationEnded
  {
    try decode(payload, as: BuildOperationEnded.self)
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
    let selected = try decodeAllExportedMacrosAndValuesResponseDictionary(
      payload,
      selecting: keys
    )
    return keys.map { selected[$0] ?? "" }
  }

  static func decodeAllExportedMacrosAndValuesResponseDictionary(
    _ payload: [UInt8],
    selecting keys: [String]
  ) throws -> [String: String] {
    let message = try decodeIPCMessage(payload)
    guard let response = message.message as? AllExportedMacrosAndValuesResponse else {
      throw SwiftBuildProtocolCodecError.unexpectedMessage(
        expected: AllExportedMacrosAndValuesResponse.name,
        actual: type(of: message.message).name
      )
    }
    // Project immediately onto the allowlist so the complete shell environment
    // cannot escape the protocol query boundary.
    return Dictionary(uniqueKeysWithValues: keys.map { ($0, response.result[$0] ?? "") })
  }

  static func encode(_ message: any Message) -> [UInt8] {
    let serializer = MsgPackSerializer()
    IPCMessage(message).serialize(to: serializer)
    return serializer.byteString.bytes
  }

  static func decodeIPCMessage(_ payload: [UInt8]) throws -> IPCMessage {
    try IPCMessage(from: MsgPackDeserializer(payload[...]))
  }

  private static func decode<T: Message>(_ payload: [UInt8], as type: T.Type) throws -> T {
    let message = try decodeIPCMessage(payload)
    guard let value = message.message as? T else {
      throw SwiftBuildProtocolCodecError.unexpectedMessage(
        expected: type.name,
        actual: Swift.type(of: message.message).name
      )
    }
    return value
  }
}
