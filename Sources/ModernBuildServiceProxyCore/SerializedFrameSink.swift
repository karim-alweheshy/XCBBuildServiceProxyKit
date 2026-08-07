import Foundation

enum SerializedFrameSinkError: LocalizedError, Equatable {
  case invalidHeaderLength(Int)
  case payloadLengthMismatch(expected: UInt32, actual: UInt32)

  var errorDescription: String? {
    switch self {
    case .invalidHeaderLength(let length):
      return "Build-service frame header has \(length) bytes instead of 12."
    case .payloadLengthMismatch(let expected, let actual):
      return "Build-service frame declared \(expected) payload bytes but wrote \(actual)."
    }
  }
}

/// Serializes complete frame transactions onto one output byte stream.
///
/// The sink owns the only writer for its destination. Its lock is held from
/// the first header byte through the final payload byte, including partial
/// write retries and streaming payload reads performed by the caller.
final class SerializedFrameSink: @unchecked Sendable {
  final class StreamingFrame {
    private let writer: FrameByteWriter
    private let expectedPayloadLength: UInt32
    private(set) var payloadBytesWritten: UInt32 = 0

    fileprivate init(writer: FrameByteWriter, expectedPayloadLength: UInt32) {
      self.writer = writer
      self.expectedPayloadLength = expectedPayloadLength
    }

    func writePayload(_ bytes: UnsafeRawBufferPointer) throws {
      let nextCount = UInt64(payloadBytesWritten) + UInt64(bytes.count)
      guard nextCount <= UInt64(expectedPayloadLength) else {
        throw SerializedFrameSinkError.payloadLengthMismatch(
          expected: expectedPayloadLength,
          actual: UInt32(clamping: nextCount)
        )
      }
      try writer.writeAll(bytes)
      payloadBytesWritten += UInt32(bytes.count)
    }

    fileprivate func finish() throws {
      guard payloadBytesWritten == expectedPayloadLength else {
        throw SerializedFrameSinkError.payloadLengthMismatch(
          expected: expectedPayloadLength,
          actual: payloadBytesWritten
        )
      }
    }
  }

  private let writer: FrameByteWriter
  private let onFirstFailure: ((any Error) -> Void)?
  private let lock = NSLock()
  private var failure: (any Error)?

  init(
    writer: FrameByteWriter,
    onFirstFailure: ((any Error) -> Void)? = nil
  ) {
    self.writer = writer
    self.onFirstFailure = onFirstFailure
  }

  var firstFailure: (any Error)? {
    lock.withLock { failure }
  }

  func send(_ frame: BuildServiceRawFrame) throws {
    let declaredPayloadLength = try Self.payloadLength(from: frame.header)
    guard declaredPayloadLength == UInt32(frame.payload.count) else {
      throw SerializedFrameSinkError.payloadLengthMismatch(
        expected: declaredPayloadLength,
        actual: UInt32(frame.payload.count)
      )
    }
    try withStreamingFrame(header: frame.header) { transaction in
      try frame.payload.withUnsafeBytes(transaction.writePayload)
    }
  }

  /// Runs a streaming frame transaction while retaining exclusive ownership
  /// of the destination. The body may read bounded chunks from the source and
  /// pass them to `writePayload`; it never receives the underlying writer.
  func withStreamingFrame(
    header: [UInt8],
    _ body: (StreamingFrame) throws -> Void
  ) throws {
    let payloadLength = try Self.payloadLength(from: header)
    var firstFailureToReport: (any Error)?

    lock.lock()
    if let failure {
      lock.unlock()
      throw failure
    }

    do {
      let transaction = StreamingFrame(
        writer: writer,
        expectedPayloadLength: payloadLength
      )
      try header.withUnsafeBytes { try writer.writeAll($0) }
      try body(transaction)
      try transaction.finish()
      lock.unlock()
    } catch {
      failure = error
      firstFailureToReport = error
      lock.unlock()
      if let firstFailureToReport {
        onFirstFailure?(firstFailureToReport)
      }
      throw error
    }
  }

  private static func payloadLength(from header: [UInt8]) throws -> UInt32 {
    guard header.count == BuildServiceFramePump.headerLength else {
      throw SerializedFrameSinkError.invalidHeaderLength(header.count)
    }
    return header[8..<12].enumerated().reduce(0) { result, element in
      result | (UInt32(element.element) << UInt32(element.offset * 8))
    }
  }
}

final class FirstErrorLatch<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  @discardableResult
  func record(_ candidate: Value) -> Bool {
    lock.withLock {
      guard value == nil else { return false }
      value = candidate
      return true
    }
  }

  var first: Value? {
    lock.withLock { value }
  }
}
