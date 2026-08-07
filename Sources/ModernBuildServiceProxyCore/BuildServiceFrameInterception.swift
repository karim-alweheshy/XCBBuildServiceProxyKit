import Foundation

public struct BuildServiceRawFrame: Equatable, Sendable {
  public let header: [UInt8]
  public let payload: [UInt8]
  public let channel: UInt64
  public let messageName: String?

  public init(channel: UInt64, payload: [UInt8], messageName: String? = nil) {
    precondition(payload.count <= Int(UInt32.max))
    self.channel = channel
    self.payload = payload
    self.messageName = messageName
    header =
      (0..<8).map { UInt8(truncatingIfNeeded: channel >> UInt64($0 * 8)) }
      + (0..<4).map {
        UInt8(truncatingIfNeeded: UInt32(payload.count) >> UInt32($0 * 8))
      }
  }

  init(header: [UInt8], payload: [UInt8], channel: UInt64, messageName: String?) {
    self.header = header
    self.payload = payload
    self.channel = channel
    self.messageName = messageName
  }
}

public enum BuildServiceFrameInterceptionFailure: Equatable, Sendable {
  case capturedPayloadTooLarge(actualBytes: UInt32, maximumBytes: UInt32)
}

/// Thread-safe routing capabilities backed by the relay's two serialized
/// output sinks. A router can explicitly send either toward the native service
/// or toward Xcode, including from asynchronous work retained after interception.
public final class BuildServiceFrameOutputs: @unchecked Sendable {
  private let nativeSender: (BuildServiceRawFrame) throws -> Void
  private let xcodeSender: (BuildServiceRawFrame) throws -> Void

  public init(
    sendToNative: @escaping (BuildServiceRawFrame) throws -> Void,
    sendToXcode: @escaping (BuildServiceRawFrame) throws -> Void
  ) {
    nativeSender = sendToNative
    xcodeSender = sendToXcode
  }

  public func sendToNative(_ frame: BuildServiceRawFrame) throws {
    try nativeSender(frame)
  }

  public func sendToXcode(_ frame: BuildServiceRawFrame) throws {
    try xcodeSender(frame)
  }
}

/// A narrow hook for opt-in Xcode protocol routing and inspection.
///
/// The core owns framing and raw forwarding. Implementations may inspect only
/// explicitly selected complete frames and must return `false` when the
/// original frame should continue to its destination unchanged.
public protocol BuildServiceFrameInterceptor: AnyObject {
  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool

  func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) -> Bool
}

extension BuildServiceFrameInterceptor {
  public func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) -> Bool { false }
}
