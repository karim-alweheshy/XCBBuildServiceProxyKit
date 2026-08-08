import Foundation
import XCTest
import libzstd

@testable import BazelProxyCore

final class BazelCompactExecutionLogTests: XCTestCase {
  func testCompactLogDecodesLocalDiskAndRemoteSpawnsAndOutputKinds() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }

    let entries = [
      compactEntry(id: 42, payloadField: 3, payload: pathEntry("bazel-out/App.swiftmodule")),
      compactEntry(id: 7, payloadField: 4, payload: pathEntry("bazel-out/App.app")),
      compactEntry(id: 99, payloadField: 5, payload: pathEntry("bazel-out/App.link")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          arguments: [
            "swiftc", "--remote_header", "Authorization=Bearer secret",
            "https://user:password@example.invalid/Input.swift",
          ],
          outputs: [.identifier(42)],
          label: "@@//app:App",
          mnemonic: "SwiftCompile",
          exitCode: 0,
          status: "SUCCESS",
          runner: "local sandbox"
        ) + protobufVarintField(99, value: 123)
          + protobufFixed64Field(100, value: 456)
          + protobufBytesField(101, value: Data([1, 2, 3]))
          + protobufFixed32Field(102, value: 789)
      ),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          arguments: ["bundle", "bazel-out/App.app"],
          outputs: [.identifier(7), .invalidPath("bazel-out/App.missing")],
          label: "//app:App",
          mnemonic: "BundleTreeApp",
          runner: "disk cache hit",
          cacheHit: true
        )
      ),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          arguments: ["ln", "-s", "App", "App.link"],
          outputs: [.identifier(99)],
          label: "//app:App",
          mnemonic: "Symlink",
          runner: "remote cache hit",
          cacheHit: true
        )
      ),
    ]
    try fixture.write(entries: entries)

    let validation = try BazelExecutionLogValidator.validate(fileAt: fixture.url)
    XCTAssertEqual(validation.records.count, 3)
    XCTAssertEqual(validation.records[0].cacheKind, .other)
    XCTAssertEqual(validation.records[0].runner, "local sandbox")
    XCTAssertEqual(validation.records[0].listedOutputs, ["bazel-out/App.swiftmodule"])
    XCTAssertEqual(validation.records[1].cacheKind, .disk)
    XCTAssertEqual(
      validation.records[1].listedOutputs,
      ["bazel-out/App.app", "bazel-out/App.missing"]
    )
    XCTAssertEqual(validation.records[2].cacheKind, .remote)
    XCTAssertEqual(validation.records[2].listedOutputs, ["bazel-out/App.link"])

    let command = try XCTUnwrap(validation.records[0].commandLineDisplayString)
    XCTAssertTrue(command.contains("<redacted>"))
    XCTAssertFalse(command.contains("secret"))
    XCTAssertFalse(command.contains("user:password"))
    XCTAssertEqual(
      validation.record(
        for: BazelActionReconciliationKey(
          label: "//app:App",
          primaryOutput: "bazel-out/App.swiftmodule"
        )
      ),
      validation.records[0]
    )
  }

  func testCompactLogIgnoresNonSpawnSymlinkAction() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }
    let symlinkAction =
      protobufStringField(1, value: "bazel-out/App")
      + protobufStringField(2, value: "bazel-out/App.link")
      + protobufStringField(3, value: "//app:App")
      + protobufStringField(4, value: "Symlink")
    try fixture.write(entries: [compactEntry(id: 300, payloadField: 8, payload: symlinkAction)])

    let validation = try BazelExecutionLogValidator.validate(fileAt: fixture.url)
    XCTAssertTrue(validation.records.isEmpty)
  }

  func testCompactLogRejectsTruncatedAndMalformedCompressionAndProtobuf() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }

    let valid = try compactLogData([
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("out"))
    ])
    try fixture.write(data: valid.dropLast())
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    var corrupt = valid
    corrupt[corrupt.index(corrupt.startIndex, offsetBy: 5)] ^= 0xFF
    try fixture.write(data: corrupt)
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(decoded: Data([0x80]))
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(decoded: Data([0x05, 0x18, 0x03]))
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(decoded: framed(Data([0x0B])))
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(decoded: framed(Data([0x1A, 0x05, 0x0A, 0x01])))
    assertCompactMalformed(tryValidation: { try fixture.validate() })
  }

  func testCompactLogRejectsMissingAndWrongOutputReferences() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }
    let referencesMissing = compactEntry(
      payloadField: 7,
      payload: spawn(outputs: [.identifier(42)], label: "//app:App")
    )
    try fixture.write(entries: [referencesMissing])
    XCTAssertThrowsError(try fixture.validate()) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .missingCompactOutputReference(42))
    }

    let inputSet = compactEntry(id: 42, payloadField: 6, payload: Data())
    try fixture.write(entries: [inputSet, referencesMissing])
    XCTAssertThrowsError(try fixture.validate()) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .wrongCompactOutputReference(42))
    }
  }

  func testCompactLogRejectsConflictingIDsRecordsAndCacheState() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }
    try fixture.write(entries: [
      compactEntry(id: 9, payloadField: 3, payload: pathEntry("first")),
      compactEntry(id: 9, payloadField: 3, payload: pathEntry("second")),
    ])
    XCTAssertThrowsError(try fixture.validate()) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .conflictingCompactEntryID(9))
    }

    try fixture.write(entries: [
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("same-output")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          outputs: [.identifier(1)], label: "//app:App", runner: "local sandbox"
        )
      ),
      compactEntry(id: 2, payloadField: 3, payload: pathEntry("same-output")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          outputs: [.identifier(2)], label: "@//app:App", runner: "remote cache hit",
          cacheHit: true
        )
      ),
    ])
    XCTAssertThrowsError(try fixture.validate()) { error in
      XCTAssertEqual(
        error as? BazelExecutionLogError,
        .ambiguousRecord(label: "//app:App", output: "same-output")
      )
    }

    try fixture.write(entries: [
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("out")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          outputs: [.identifier(1)], label: "//app:App", exitCode: 1,
          status: "FAILED", runner: "disk cache hit", cacheHit: true
        )
      ),
    ])
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(entries: [
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("out")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          outputs: [.identifier(1)], label: "//app:App", runner: "local sandbox",
          cacheHit: true
        )
      ),
    ])
    assertCompactMalformed(tryValidation: { try fixture.validate() })

    try fixture.write(entries: [
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("out")),
      compactEntry(
        payloadField: 7,
        payload: spawn(
          outputs: [.identifier(1)], label: "//app:App", runner: "disk cache hit"
        )
      ),
    ])
    assertCompactMalformed(tryValidation: { try fixture.validate() })
  }

  func testCompactLogEnforcesCompressedDecodedRecordAndRecordCountLimits() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }
    let entry = compactEntry(id: 1, payloadField: 3, payload: pathEntry("output"))
    try fixture.write(entries: [entry])

    XCTAssertThrowsError(
      try fixture.validate(
        limits: BazelExecutionLogLimits(maximumFileBytes: 8, maximumLineBytes: 4)
      )
    ) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .fileLimitExceeded(8))
    }

    try fixture.write(decoded: Data(repeating: 0, count: 128))
    XCTAssertThrowsError(
      try fixture.validate(
        limits: BazelExecutionLogLimits(
          maximumFileBytes: 1_024,
          maximumLineBytes: 64,
          maximumDecodedBytes: 64
        )
      )
    ) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .compactDecodedLimitExceeded(64))
    }

    try fixture.write(entries: [entry])
    XCTAssertThrowsError(
      try fixture.validate(
        limits: BazelExecutionLogLimits(
          maximumFileBytes: 1_024,
          maximumLineBytes: 4,
          maximumDecodedBytes: 1_024
        )
      )
    ) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .lineLimitExceeded(4))
    }

    try fixture.write(entries: [
      entry,
      compactEntry(id: 2, payloadField: 3, payload: pathEntry("two")),
    ])
    XCTAssertThrowsError(
      try fixture.validate(
        limits: BazelExecutionLogLimits(
          maximumFileBytes: 1_024,
          maximumLineBytes: 512,
          maximumDecodedBytes: 1_024,
          maximumRecordCount: 1
        )
      )
    ) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .compactRecordLimitExceeded(1))
    }
  }

  func testCompactLogRejectsSymlinkAndNonRegularInputs() throws {
    let fixture = try TemporaryCompactExecutionLog()
    defer { fixture.remove() }
    try fixture.write(entries: [
      compactEntry(id: 1, payloadField: 3, payload: pathEntry("output"))
    ])
    let linked = fixture.root.appendingPathComponent("linked.compact")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.url)
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: linked)) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .unsafeFile(linked.path))
    }
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: fixture.root)) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .unsafeFile(fixture.root.path))
    }
  }
}

private enum SyntheticOutput {
  case identifier(UInt32)
  case invalidPath(String)
}

private struct TemporaryCompactExecutionLog {
  let root: URL
  let url: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    url = root.appendingPathComponent("execution-log.compact")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func write(entries: [Data]) throws {
    try write(data: compactLogData(entries))
  }

  func write(decoded: Data) throws {
    try write(data: zstdCompress(decoded))
  }

  func write<T: DataProtocol>(data: T) throws {
    try Data(data).write(to: url, options: .atomic)
  }

  func validate(
    limits: BazelExecutionLogLimits = BazelExecutionLogLimits()
  ) throws -> BazelExecutionLogValidation {
    try BazelExecutionLogValidator.validate(fileAt: url, limits: limits)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func compactLogData(_ entries: [Data]) throws -> Data {
  try zstdCompress(entries.reduce(into: Data()) { $0.append(framed($1)) })
}

private func compactEntry(
  id: UInt32 = 0,
  payloadField: Int,
  payload: Data
) -> Data {
  var result = Data()
  if id != 0 { result.append(protobufVarintField(1, value: UInt64(id))) }
  result.append(protobufBytesField(payloadField, value: payload))
  return result
}

private func pathEntry(_ path: String) -> Data {
  protobufStringField(1, value: path)
}

private func spawn(
  arguments: [String] = [],
  outputs: [SyntheticOutput],
  label: String,
  mnemonic: String = "Action",
  exitCode: Int32? = nil,
  status: String? = nil,
  runner: String? = nil,
  cacheHit: Bool = false
) -> Data {
  var result = Data()
  for argument in arguments { result.append(protobufStringField(1, value: argument)) }
  for output in outputs {
    let encoded: Data
    switch output {
    case .identifier(let identifier):
      encoded = protobufVarintField(5, value: UInt64(identifier))
    case .invalidPath(let path):
      encoded = protobufStringField(4, value: path)
    }
    result.append(protobufBytesField(6, value: encoded))
  }
  result.append(protobufStringField(7, value: label))
  result.append(protobufStringField(8, value: mnemonic))
  if let exitCode {
    result.append(protobufVarintField(9, value: UInt64(UInt32(bitPattern: exitCode))))
  }
  if let status { result.append(protobufStringField(10, value: status)) }
  if let runner { result.append(protobufStringField(11, value: runner)) }
  if cacheHit { result.append(protobufVarintField(12, value: 1)) }
  return result
}

private func framed(_ message: Data) -> Data {
  protobufVarint(UInt64(message.count)) + message
}

private func protobufStringField(_ number: Int, value: String) -> Data {
  protobufBytesField(number, value: Data(value.utf8))
}

private func protobufBytesField(_ number: Int, value: Data) -> Data {
  protobufVarint(UInt64(number << 3 | 2)) + protobufVarint(UInt64(value.count)) + value
}

private func protobufVarintField(_ number: Int, value: UInt64) -> Data {
  protobufVarint(UInt64(number << 3)) + protobufVarint(value)
}

private func protobufFixed64Field(_ number: Int, value: UInt64) -> Data {
  var littleEndian = value.littleEndian
  return protobufVarint(UInt64(number << 3 | 1))
    + withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func protobufFixed32Field(_ number: Int, value: UInt32) -> Data {
  var littleEndian = value.littleEndian
  return protobufVarint(UInt64(number << 3 | 5))
    + withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func protobufVarint(_ value: UInt64) -> Data {
  var remaining = value
  var result = Data()
  while remaining >= 0x80 {
    result.append(UInt8(remaining & 0x7F) | 0x80)
    remaining >>= 7
  }
  result.append(UInt8(remaining))
  return result
}

private func zstdCompress(_ data: Data) throws -> Data {
  let capacity = ZSTD_compressBound(data.count)
  var output = Data(count: capacity)
  let compressedCount = try output.withUnsafeMutableBytes { outputBytes in
    try data.withUnsafeBytes { inputBytes -> Int in
      guard let destination = outputBytes.baseAddress, let source = inputBytes.baseAddress else {
        throw SyntheticCompactLogError.compressionFailed
      }
      let result = ZSTD_compress(destination, outputBytes.count, source, inputBytes.count, 1)
      guard ZSTD_isError(result) == 0 else { throw SyntheticCompactLogError.compressionFailed }
      return result
    }
  }
  output.count = compressedCount
  return output
}

private func assertCompactMalformed(
  tryValidation: () throws -> BazelExecutionLogValidation,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertThrowsError(try tryValidation(), file: file, line: line) { error in
    XCTAssertEqual(
      error as? BazelExecutionLogError,
      .malformedCompactLog,
      file: file,
      line: line
    )
  }
}

private enum SyntheticCompactLogError: Error {
  case compressionFailed
}
