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

public enum BuildServiceFrameOutputsError: LocalizedError, Equatable, Sendable {
  case relayClosed

  public var errorDescription: String? {
    "The build-service relay no longer accepts injected frames."
  }
}

/// Thread-safe routing capabilities backed by the relay's two serialized
/// output sinks. A router can explicitly send either toward the native service
/// or toward Xcode, including from asynchronous work retained after interception.
public final class BuildServiceFrameOutputs: @unchecked Sendable {
  private let condition = NSCondition()
  private let nativeSender: (BuildServiceRawFrame) throws -> Void
  private let xcodeSender: (BuildServiceRawFrame) throws -> Void
  private var nativeInFlightSendCount = 0
  private var xcodeInFlightSendCount = 0
  private var isNativeOpen = true
  private var isXcodeOpen = true

  public init(
    sendToNative: @escaping (BuildServiceRawFrame) throws -> Void,
    sendToXcode: @escaping (BuildServiceRawFrame) throws -> Void
  ) {
    nativeSender = sendToNative
    xcodeSender = sendToXcode
  }

  public func sendToNative(_ frame: BuildServiceRawFrame) throws {
    try send(frame, direction: .native, using: nativeSender)
  }

  public func sendToXcode(_ frame: BuildServiceRawFrame) throws {
    try send(frame, direction: .xcode, using: xcodeSender)
  }

  @discardableResult
  func closeNativeAndWait(timeout: TimeInterval? = nil) -> Bool {
    closeAndWait(native: true, xcode: false, timeout: timeout)
  }

  func closeNative() {
    condition.lock()
    isNativeOpen = false
    condition.broadcast()
    condition.unlock()
  }

  func closeAll() {
    condition.lock()
    isNativeOpen = false
    isXcodeOpen = false
    condition.broadcast()
    condition.unlock()
  }

  @discardableResult
  func closeAndWait(timeout: TimeInterval? = nil) -> Bool {
    closeAndWait(native: true, xcode: true, timeout: timeout)
  }

  private enum Direction {
    case native
    case xcode
  }

  private func closeAndWait(
    native: Bool,
    xcode: Bool,
    timeout: TimeInterval?
  ) -> Bool {
    condition.lock()
    if native { isNativeOpen = false }
    if xcode { isXcodeOpen = false }
    let deadline = timeout.map { Date(timeIntervalSinceNow: max(0, $0)) }
    while (native && nativeInFlightSendCount > 0) || (xcode && xcodeInFlightSendCount > 0) {
      if let deadline, !condition.wait(until: deadline) {
        condition.unlock()
        return false
      }
      if deadline == nil { condition.wait() }
    }
    condition.unlock()
    return true
  }

  private func send(
    _ frame: BuildServiceRawFrame,
    direction: Direction,
    using sender: (BuildServiceRawFrame) throws -> Void
  ) throws {
    condition.lock()
    let isOpen = direction == .native ? isNativeOpen : isXcodeOpen
    guard isOpen else {
      condition.unlock()
      throw BuildServiceFrameOutputsError.relayClosed
    }
    switch direction {
    case .native: nativeInFlightSendCount += 1
    case .xcode: xcodeInFlightSendCount += 1
    }
    condition.unlock()
    defer {
      condition.lock()
      switch direction {
      case .native: nativeInFlightSendCount -= 1
      case .xcode: xcodeInFlightSendCount -= 1
      }
      condition.broadcast()
      condition.unlock()
    }
    try sender(frame)
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
  ) throws -> Bool

  /// Called after the native service and frame pumps stop, before output capabilities close.
  func buildServiceRelayWillClose()

  /// Waits for retained asynchronous interception work to stop using relay output capabilities.
  func buildServiceRelayWaitForQuiescence(timeout: TimeInterval) -> Bool
}

extension BuildServiceFrameInterceptor {
  public func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) throws -> Bool { false }

  public func buildServiceRelayWillClose() {}

  public func buildServiceRelayWaitForQuiescence(timeout: TimeInterval) -> Bool { true }
}
