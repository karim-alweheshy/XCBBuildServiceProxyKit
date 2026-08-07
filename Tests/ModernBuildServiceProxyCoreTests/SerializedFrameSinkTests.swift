import CryptoKit
import Foundation
import XCTest

@testable import ModernBuildServiceProxyCore

final class SerializedFrameSinkTests: XCTestCase {
  func testOversizeUncapturedFrameStreamsWithBoundedChunksAndExactDigest() throws {
    let payloadLength = BuildServiceFramePump.maximumInterceptedPayloadLength + 1
    let channel: UInt64 = 0x1020_3040
    let payloadByte: UInt8 = 0xA5
    let header = makeHeader(channel: channel, payloadLength: payloadLength)
    let reader = RepeatingPayloadFrameReader(
      header: header,
      payloadLength: payloadLength,
      payloadByte: payloadByte
    )
    let writer = DigestingWriter(maximumWriteLength: 4096)
    let sink = SerializedFrameSink(writer: writer)
    let interceptor = OversizeForwardingInterceptor()
    let outputs = BuildServiceFrameOutputs(
      sendToNative: sink.send,
      sendToXcode: { _ in XCTFail("Unexpected Xcode-bound injection") }
    )

    let summary = try BuildServiceFramePump(
      direction: .clientToService,
      reader: reader,
      sink: sink,
      recorder: nil,
      interceptor: interceptor,
      outputs: outputs
    ).run()

    XCTAssertEqual(summary.frameCount, 1)
    XCTAssertEqual(
      summary.byteCount,
      UInt64(BuildServiceFramePump.headerLength) + UInt64(payloadLength)
    )
    XCTAssertEqual(writer.byteCount, Int(summary.byteCount))
    XCTAssertLessThanOrEqual(writer.largestBufferSeen, 64 * 1024)
    XCTAssertEqual(
      writer.digest, digest(header: header, payloadLength: payloadLength, byte: payloadByte))
    XCTAssertEqual(
      interceptor.failure,
      .capturedPayloadTooLarge(
        actualBytes: payloadLength,
        maximumBytes: BuildServiceFramePump.maximumInterceptedPayloadLength
      )
    )
  }

  func testConcurrentForwardingAndInjectionsRemainWholeFramesWithOneByteWriter() throws {
    let writer = OneByteWriter()
    let sink = SerializedFrameSink(writer: writer)
    let forwarded = (0..<40).map { sequence in
      makeRawFrame(
        source: 1,
        sequence: sequence,
        payload: sequence == 0 ? [] : Array(repeating: UInt8(sequence), count: sequence % 17 + 1)
      )
    }
    let input = forwarded.flatMap { $0.header + $0.payload }
    let result = LockedBox<Result<BuildServiceFramePumpSummary, Error>?>(nil)
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      result.set(
        Result {
          try BuildServiceFramePump(
            direction: .serviceToClient,
            reader: FragmentedBytesReader(bytes: input, maximumReadLength: 7),
            sink: sink,
            recorder: nil
          ).run()
        }
      )
      group.leave()
    }

    let injectedSourceCount = 5
    let injectedFramesPerSource = 30
    for source in 2..<(2 + injectedSourceCount) {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          for sequence in 0..<injectedFramesPerSource {
            try sink.send(
              makeRawFrame(
                source: source,
                sequence: sequence,
                payload: sequence == 0
                  ? [] : [UInt8(source), UInt8(sequence), UInt8(source ^ sequence)]
              )
            )
          }
        } catch {
          XCTFail("Unexpected injected-frame failure: \(error)")
        }
        group.leave()
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    let pumpSummary = try XCTUnwrap(result.get()).get()
    XCTAssertEqual(pumpSummary.frameCount, UInt64(forwarded.count))
    XCTAssertEqual(pumpSummary.byteCount, UInt64(input.count))

    let decoded = try decodeFrames(writer.bytes)
    XCTAssertEqual(
      decoded.count,
      forwarded.count + injectedSourceCount * injectedFramesPerSource
    )
    for source in 1..<(2 + injectedSourceCount) {
      let expectedCount = source == 1 ? forwarded.count : injectedFramesPerSource
      XCTAssertEqual(
        decoded.filter { $0.source == source }.map(\.sequence),
        Array(0..<expectedCount),
        "Per-source FIFO order changed for source \(source)"
      )
    }
    XCTAssertEqual(writer.writeCount, writer.bytes.count)
  }

  func testInjectionWaitsUntilHeldForwardedPayloadCompletes() throws {
    let writer = HeaderHoldingOneByteWriter()
    let sink = SerializedFrameSink(writer: writer)
    let forwarded = makeRawFrame(source: 1, sequence: 1, payload: [1, 2, 3, 4])
    let injected = makeRawFrame(source: 2, sequence: 1, payload: [9, 8, 7])
    let group = DispatchGroup()
    let injectionAttempted = DispatchSemaphore(value: 0)
    let injectionFinished = DispatchSemaphore(value: 0)
    let errors = LockedBox<[String]>([])

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try sink.send(forwarded)
      } catch {
        errors.mutate { $0.append(error.localizedDescription) }
      }
      group.leave()
    }

    XCTAssertEqual(writer.headerCompleted.wait(timeout: .now() + 2), .success)
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      injectionAttempted.signal()
      do {
        try sink.send(injected)
      } catch {
        errors.mutate { $0.append(error.localizedDescription) }
      }
      injectionFinished.signal()
      group.leave()
    }

    XCTAssertEqual(injectionAttempted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(injectionFinished.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(writer.bytes, forwarded.header)

    writer.releasePayload.signal()
    XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(errors.get().isEmpty)
    XCTAssertEqual(
      writer.bytes,
      forwarded.header + forwarded.payload + injected.header + injected.payload
    )
  }

  func testFirstSinkFailureIsLatchedAndRejectsLaterWrites() {
    let writer = ChangingFailureWriter(successfulWriteCount: 4)
    let callbackErrors = LockedBox<[WriterFailure]>([])
    let sink = SerializedFrameSink(
      writer: writer,
      onFirstFailure: { error in
        if let error = error as? WriterFailure {
          callbackErrors.mutate { $0.append(error) }
        }
      }
    )
    let frame = makeRawFrame(source: 1, sequence: 1, payload: [1, 2, 3])

    XCTAssertThrowsError(try sink.send(frame)) {
      XCTAssertEqual($0 as? WriterFailure, .first)
    }
    let writeCountAfterFirstFailure = writer.writeCount
    XCTAssertThrowsError(try sink.send(frame)) {
      XCTAssertEqual($0 as? WriterFailure, .first)
    }

    XCTAssertEqual(writer.writeCount, writeCountAfterFirstFailure)
    XCTAssertEqual(sink.firstFailure as? WriterFailure, .first)
    XCTAssertEqual(callbackErrors.get(), [.first])
  }
}

private struct DecodedFrame {
  let source: Int
  let sequence: Int
}

private func makeRawFrame(
  source: Int,
  sequence: Int,
  payload: [UInt8]
) -> BuildServiceRawFrame {
  BuildServiceRawFrame(
    channel: UInt64(source) << 32 | UInt64(sequence),
    payload: payload
  )
}

private func makeHeader(channel: UInt64, payloadLength: UInt32) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: channel >> UInt64($0 * 8)) }
    + (0..<4).map { UInt8(truncatingIfNeeded: payloadLength >> UInt32($0 * 8)) }
}

private func digest(header: [UInt8], payloadLength: UInt32, byte: UInt8) -> String {
  var hasher = SHA256()
  hasher.update(data: Data(header))
  let chunk = Data(repeating: byte, count: 64 * 1024)
  var remaining = Int(payloadLength)
  while remaining > 0 {
    let count = min(remaining, chunk.count)
    hasher.update(data: chunk.prefix(count))
    remaining -= count
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func decodeFrames(_ bytes: [UInt8]) throws -> [DecodedFrame] {
  var frames: [DecodedFrame] = []
  var offset = 0
  while offset < bytes.count {
    guard bytes.count - offset >= BuildServiceFramePump.headerLength else {
      throw DecodeFailure.truncatedHeader
    }
    let channel = decodeUInt64(bytes[offset..<(offset + 8)])
    let payloadLength = Int(decodeUInt32(bytes[(offset + 8)..<(offset + 12)]))
    let frameEnd = offset + BuildServiceFramePump.headerLength + payloadLength
    guard frameEnd <= bytes.count else {
      throw DecodeFailure.truncatedPayload
    }
    frames.append(
      DecodedFrame(
        source: Int(channel >> 32),
        sequence: Int(channel & 0xFFFF_FFFF)
      )
    )
    offset = frameEnd
  }
  return frames
}

private enum DecodeFailure: Error {
  case truncatedHeader
  case truncatedPayload
}

private func decodeUInt64(_ bytes: ArraySlice<UInt8>) -> UInt64 {
  bytes.enumerated().reduce(0) { result, element in
    result | UInt64(element.element) << UInt64(element.offset * 8)
  }
}

private func decodeUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
  bytes.enumerated().reduce(0) { result, element in
    result | UInt32(element.element) << UInt32(element.offset * 8)
  }
}

private final class FragmentedBytesReader: FrameByteReader {
  private let bytes: [UInt8]
  private let maximumReadLength: Int
  private var offset = 0

  init(bytes: [UInt8], maximumReadLength: Int) {
    self.bytes = bytes
    self.maximumReadLength = maximumReadLength
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard offset < bytes.count else { return 0 }
    let count = min(buffer.count, maximumReadLength, bytes.count - offset)
    bytes.withUnsafeBytes { source in
      buffer.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + count)]))
    }
    offset += count
    return count
  }
}

private final class RepeatingPayloadFrameReader: FrameByteReader {
  private let header: [UInt8]
  private let payloadLength: UInt32
  private let payloadByte: UInt8
  private var headerOffset = 0
  private var payloadOffset: UInt32 = 0

  init(header: [UInt8], payloadLength: UInt32, payloadByte: UInt8) {
    self.header = header
    self.payloadLength = payloadLength
    self.payloadByte = payloadByte
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    if headerOffset < header.count {
      let count = min(buffer.count, header.count - headerOffset)
      header.withUnsafeBytes { source in
        buffer.copyBytes(
          from: UnsafeRawBufferPointer(
            rebasing: source[headerOffset..<(headerOffset + count)]
          )
        )
      }
      headerOffset += count
      return count
    }
    guard payloadOffset < payloadLength else { return 0 }
    let count = min(buffer.count, Int(payloadLength - payloadOffset))
    UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
      .initializeMemory(as: UInt8.self, repeating: payloadByte)
    payloadOffset += UInt32(count)
    return count
  }
}

private final class DigestingWriter: FrameByteWriter {
  private let maximumWriteLength: Int
  private var hasher = SHA256()
  private(set) var byteCount = 0
  private(set) var largestBufferSeen = 0

  init(maximumWriteLength: Int) {
    self.maximumWriteLength = maximumWriteLength
  }

  var digest: String {
    let copy = hasher
    return copy.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    let count = min(maximumWriteLength, buffer.count)
    largestBufferSeen = max(largestBufferSeen, buffer.count)
    hasher.update(data: Data(buffer.prefix(count)))
    byteCount += count
    return count
  }
}

private final class OversizeForwardingInterceptor: BuildServiceFrameInterceptor {
  private(set) var failure: BuildServiceFrameInterceptionFailure?

  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool { true }

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    XCTFail("Oversize frame should not be captured")
    return false
  }

  func interceptionDidFail(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    messageName: String?,
    failure: BuildServiceFrameInterceptionFailure
  ) -> Bool {
    self.failure = failure
    return false
  }
}

private final class OneByteWriter: FrameByteWriter {
  private(set) var bytes: [UInt8] = []
  private(set) var writeCount = 0

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    guard !buffer.isEmpty else { return 0 }
    bytes.append(buffer[0])
    writeCount += 1
    return 1
  }
}

private final class HeaderHoldingOneByteWriter: FrameByteWriter {
  let headerCompleted = DispatchSemaphore(value: 0)
  let releasePayload = DispatchSemaphore(value: 0)
  private(set) var bytes: [UInt8] = []
  private var hasHeldPayload = false

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    guard !buffer.isEmpty else { return 0 }
    if bytes.count == BuildServiceFramePump.headerLength, !hasHeldPayload {
      hasHeldPayload = true
      headerCompleted.signal()
      releasePayload.wait()
    }
    bytes.append(buffer[0])
    return 1
  }
}

private enum WriterFailure: LocalizedError, Equatable {
  case first
  case later

  var errorDescription: String? {
    switch self {
    case .first: return "first writer failure"
    case .later: return "later writer failure"
    }
  }
}

private final class ChangingFailureWriter: FrameByteWriter {
  private let successfulWriteCount: Int
  private(set) var writeCount = 0

  init(successfulWriteCount: Int) {
    self.successfulWriteCount = successfulWriteCount
  }

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    writeCount += 1
    if writeCount == successfulWriteCount + 1 {
      throw WriterFailure.first
    }
    if writeCount > successfulWriteCount + 1 {
      throw WriterFailure.later
    }
    return min(1, buffer.count)
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.withLock { value }
  }

  func set(_ value: Value) {
    lock.withLock { self.value = value }
  }

  func mutate(_ body: (inout Value) -> Void) {
    lock.withLock { body(&value) }
  }
}
