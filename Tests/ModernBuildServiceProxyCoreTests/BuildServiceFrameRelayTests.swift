import CryptoKit
import Foundation
import XCTest

@testable import ModernBuildServiceProxyCore

final class BuildServiceFrameRelayTests: XCTestCase {
  func testForwardsUnknownNoncanonicalFramesByteIdenticallyWithPartialIO() throws {
    let unknownMessage = Array("FUTURE_MESSAGE".utf8)
    let sensitiveBody = Array("sensitive-body-value".utf8)
    let noncanonicalPayload =
      [0xD9, UInt8(unknownMessage.count)] + unknownMessage
      + [0xCC, 0x2A, 0x81, 0xA1, 0x78, 0xCC, 0x01] + sensitiveBody
    let exitPayload = Array("EXIT".utf8)
    let inputBytes =
      makeFrame(channel: 0x0102_0304_0506_0708, payload: noncanonicalPayload)
      + makeFrame(channel: 0, payload: exitPayload)
    let reader = FragmentedReader(
      bytes: inputBytes,
      fragmentSizes: [1, 2, 4, 3, 7, 5, 11]
    )
    let writer = ShortWriter(maximumWriteLength: 3)
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let recorder = try BuildServiceFrameMetadataRecorder(fileURL: fixture.fileURL)

    let summary = try BuildServiceFramePump(
      direction: .clientToService,
      reader: reader,
      writer: writer,
      recorder: recorder
    ).run()

    XCTAssertEqual(writer.bytes, inputBytes)
    XCTAssertEqual(summary.frameCount, 2)
    XCTAssertEqual(summary.byteCount, UInt64(inputBytes.count))
    XCTAssertGreaterThan(writer.writeCount, 2)

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    XCTAssertEqual(permissions & 0o777, 0o600)

    let metadataData = try Data(contentsOf: fixture.fileURL)
    let metadataText = try XCTUnwrap(String(data: metadataData, encoding: .utf8))
    XCTAssertFalse(metadataText.contains("sensitive-body-value"))
    XCTAssertFalse(metadataText.contains("environment"))
    XCTAssertFalse(metadataText.contains("payload\""))

    let records = try metadataText.split(separator: "\n").map {
      try JSONDecoder().decode(BuildServiceFrameMetadata.self, from: Data($0.utf8))
    }
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records[0].sequence, 1)
    XCTAssertEqual(records[0].directionSequence, 1)
    XCTAssertEqual(records[0].direction, .clientToService)
    XCTAssertEqual(records[0].channel, 0x0102_0304_0506_0708)
    XCTAssertEqual(records[0].payloadLength, UInt32(noncanonicalPayload.count))
    XCTAssertEqual(records[0].messageName, "FUTURE_MESSAGE")
    XCTAssertEqual(records[0].payloadSHA256, sha256Hex(noncanonicalPayload))
    XCTAssertEqual(records[1].sequence, 2)
    XCTAssertEqual(records[1].directionSequence, 2)
    XCTAssertEqual(records[1].channel, 0)
    XCTAssertNil(records[1].messageName)
    XCTAssertEqual(records[1].payloadSHA256, sha256Hex(exitPayload))
  }

  func testRejectsTruncatedHeaderWithoutForwarding() {
    let reader = FragmentedReader(bytes: Array(repeating: 0, count: 11), fragmentSizes: [4, 7])
    let writer = ShortWriter(maximumWriteLength: 2)

    XCTAssertThrowsError(
      try BuildServiceFramePump(
        direction: .clientToService,
        reader: reader,
        writer: writer,
        recorder: nil
      ).run()
    ) { error in
      XCTAssertEqual(
        error as? BuildServiceFrameRelayError,
        .truncatedHeader(actualBytes: 11)
      )
    }
    XCTAssertTrue(writer.bytes.isEmpty)
  }

  func testRejectsOversizeBeforePayloadReadOrHeaderForwarding() {
    let oversize = UInt32(Int32.max) + 1
    let bytes = makeHeader(channel: 42, payloadLength: oversize)
    let reader = FragmentedReader(bytes: bytes, fragmentSizes: [12])
    let writer = ShortWriter(maximumWriteLength: 12)

    XCTAssertThrowsError(
      try BuildServiceFramePump(
        direction: .serviceToClient,
        reader: reader,
        writer: writer,
        recorder: nil
      ).run()
    ) { error in
      XCTAssertEqual(error as? BuildServiceFrameRelayError, .payloadTooLarge(oversize))
    }
    XCTAssertEqual(reader.totalBytesRead, 12)
    XCTAssertTrue(writer.bytes.isEmpty)
  }

  func testRejectsTruncatedPayloadAndDoesNotRecordPartialFrame() throws {
    let declaredLength: UInt32 = 10
    let bytes = makeHeader(channel: 7, payloadLength: declaredLength) + [0xA1, 0x58, 0x01]
    let reader = FragmentedReader(bytes: bytes, fragmentSizes: [12, 2, 1])
    let writer = ShortWriter(maximumWriteLength: 4)
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let recorder = try BuildServiceFrameMetadataRecorder(fileURL: fixture.fileURL)

    XCTAssertThrowsError(
      try BuildServiceFramePump(
        direction: .serviceToClient,
        reader: reader,
        writer: writer,
        recorder: recorder
      ).run()
    ) { error in
      XCTAssertEqual(
        error as? BuildServiceFrameRelayError,
        .truncatedPayload(expectedBytes: declaredLength, actualBytes: 3)
      )
    }
    XCTAssertEqual(writer.bytes, bytes)
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), Data())
  }

  func testMetadataRecorderRejectsExistingDestination() throws {
    let fixture = try MetadataFixture(createFile: true)
    defer { fixture.remove() }

    XCTAssertThrowsError(try BuildServiceFrameMetadataRecorder(fileURL: fixture.fileURL)) { error in
      XCTAssertEqual(
        error as? BuildServiceFrameRelayError,
        .metadataFileAlreadyExists(fixture.fileURL.path)
      )
    }
  }
}

private final class FragmentedReader: FrameByteReader {
  private let bytes: [UInt8]
  private let fragmentSizes: [Int]
  private var offset = 0
  private var fragmentIndex = 0

  var totalBytesRead: Int { offset }

  init(bytes: [UInt8], fragmentSizes: [Int]) {
    self.bytes = bytes
    self.fragmentSizes = fragmentSizes
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard offset < bytes.count else { return 0 }
    let fragmentSize = fragmentSizes[fragmentIndex % fragmentSizes.count]
    fragmentIndex += 1
    let count = min(buffer.count, fragmentSize, bytes.count - offset)
    bytes.withUnsafeBytes { source in
      let sourceSlice = UnsafeRawBufferPointer(rebasing: source[offset..<(offset + count)])
      buffer.copyBytes(from: sourceSlice)
    }
    offset += count
    return count
  }
}

private final class ShortWriter: FrameByteWriter {
  private let maximumWriteLength: Int
  private(set) var bytes: [UInt8] = []
  private(set) var writeCount = 0

  init(maximumWriteLength: Int) {
    self.maximumWriteLength = maximumWriteLength
  }

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    let count = min(maximumWriteLength, buffer.count)
    bytes.append(contentsOf: buffer.prefix(count))
    writeCount += 1
    return count
  }
}

private final class MetadataFixture {
  let directoryURL: URL
  let fileURL: URL

  init(createFile: Bool = false) throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("frames.jsonl", isDirectory: false)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if createFile {
      XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private func makeFrame(channel: UInt64, payload: [UInt8]) -> [UInt8] {
  makeHeader(channel: channel, payloadLength: UInt32(payload.count)) + payload
}

private func makeHeader(channel: UInt64, payloadLength: UInt32) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: channel >> UInt64($0 * 8)) }
    + (0..<4).map { UInt8(truncatingIfNeeded: payloadLength >> UInt32($0 * 8)) }
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
  SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}
