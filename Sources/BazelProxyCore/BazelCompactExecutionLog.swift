import Foundation
import libzstd

/// Decodes Bazel 9.2's zstd-compressed stream of length-delimited `ExecLogEntry` messages.
/// Only spawn presentation fields and output-path references from `spawn.proto` are retained.
enum BazelCompactExecutionLogDecoder {
  private static let decompressionChunkBytes = 64 * 1024
  private static let maximumInitialDecodedCapacity = 8 * 1024 * 1024

  static func decode(
    _ compressed: Data,
    limits: BazelExecutionLogLimits
  ) throws -> [BazelExecutionRecord] {
    let data = try decompress(compressed, maximumBytes: limits.maximumDecodedBytes)
    var stream = ProtoReader(data)
    var references = [UInt32: CompactReference]()
    var records = [BazelExecutionRecord]()
    var recordCount = 0

    while !stream.isAtEnd {
      guard recordCount < limits.maximumRecordCount else {
        throw BazelExecutionLogError.compactRecordLimitExceeded(limits.maximumRecordCount)
      }
      let recordData = try stream.readLengthDelimited(maximumBytes: limits.maximumLineBytes)
      recordCount += 1
      if let record = try parseEntry(
        recordData,
        references: &references,
        limits: limits
      ) {
        records.append(record)
      }
    }
    return records
  }

  private static func decompress(
    _ compressed: Data,
    maximumBytes: Int
  ) throws -> Data {
    guard let stream = ZSTD_createDStream() else {
      throw BazelExecutionLogError.malformedCompactLog
    }
    defer { ZSTD_freeDStream(stream) }
    let initialization = ZSTD_initDStream(stream)
    guard ZSTD_isError(initialization) == 0 else {
      throw BazelExecutionLogError.malformedCompactLog
    }

    var decoded = Data()
    decoded.reserveCapacity(
      min(min(compressed.count * 4, maximumBytes), maximumInitialDecodedCapacity)
    )
    var finalResult = initialization
    try compressed.withUnsafeBytes { compressedBytes in
      guard let source = compressedBytes.baseAddress else {
        throw BazelExecutionLogError.malformedCompactLog
      }
      var input = ZSTD_inBuffer(src: source, size: compressedBytes.count, pos: 0)
      var outputBytes = [UInt8](repeating: 0, count: decompressionChunkBytes)
      while input.pos < input.size {
        let previousInputPosition = input.pos
        var produced = 0
        finalResult = outputBytes.withUnsafeMutableBytes { bytes in
          var output = ZSTD_outBuffer(dst: bytes.baseAddress, size: bytes.count, pos: 0)
          let result = ZSTD_decompressStream(stream, &output, &input)
          produced = output.pos
          return result
        }
        guard ZSTD_isError(finalResult) == 0,
          input.pos > previousInputPosition || produced > 0
        else { throw BazelExecutionLogError.malformedCompactLog }
        guard produced <= maximumBytes - decoded.count else {
          throw BazelExecutionLogError.compactDecodedLimitExceeded(maximumBytes)
        }
        decoded.append(contentsOf: outputBytes.prefix(produced))
      }
    }
    guard finalResult == 0 else { throw BazelExecutionLogError.malformedCompactLog }
    return decoded
  }

  private static func parseEntry(
    _ data: Data,
    references: inout [UInt32: CompactReference],
    limits: BazelExecutionLogLimits
  ) throws -> BazelExecutionRecord? {
    var reader = ProtoReader(data)
    var identifier: UInt32 = 0
    var payload = CompactPayload.other

    while !reader.isAtEnd {
      let field = try reader.readField()
      switch field.number {
      case 1:
        try field.require(.varint)
        identifier = try reader.readUInt32()
      case 3:
        try field.require(.lengthDelimited)
        payload = .reference(
          try parseReference(
            reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes),
            kind: .file
          )
        )
      case 4:
        try field.require(.lengthDelimited)
        payload = .reference(
          try parseReference(
            reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes),
            kind: .directory
          )
        )
      case 5:
        try field.require(.lengthDelimited)
        payload = .reference(
          try parseReference(
            reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes),
            kind: .unresolvedSymlink
          )
        )
      case 7:
        try field.require(.lengthDelimited)
        payload = .spawn(
          try parseSpawn(
            reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes),
            references: references,
            limits: limits
          )
        )
      case 8:
        try field.require(.lengthDelimited)
        try validateSymlinkAction(
          reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes)
        )
        payload = .other
      default:
        try reader.skip(field.wireType)
        if (2...10).contains(field.number) {
          payload = .other
        }
      }
    }

    if identifier != 0 {
      let reference: CompactReference
      switch payload {
      case .reference(let value): reference = value
      case .other, .spawn: reference = CompactReference(kind: .other, path: nil)
      }
      // Bazel's schema requires every nonzero ID to be unique. Reject even byte-identical
      // duplicates so later output references can never acquire order-dependent meaning.
      guard references[identifier] == nil else {
        throw BazelExecutionLogError.conflictingCompactEntryID(identifier)
      }
      references[identifier] = reference
    }

    if case .spawn(let record) = payload { return record }
    return nil
  }

  private static func parseReference(
    _ data: Data,
    kind: CompactReference.Kind
  ) throws -> CompactReference {
    var reader = ProtoReader(data)
    var path: String?
    while !reader.isAtEnd {
      let field = try reader.readField()
      if field.number == 1 {
        try field.require(.lengthDelimited)
        path = try reader.readString()
      } else {
        try reader.skip(field.wireType)
      }
    }
    guard let path, !path.isEmpty else { throw BazelExecutionLogError.malformedCompactLog }
    return CompactReference(kind: kind, path: path)
  }

  private static func parseSpawn(
    _ data: Data,
    references: [UInt32: CompactReference],
    limits: BazelExecutionLogLimits
  ) throws -> BazelExecutionRecord {
    var reader = ProtoReader(data)
    var arguments = [String]()
    var commandDisplayExceededLimits = false
    var cacheHit = false
    var exitCode: Int?
    var mnemonic: String?
    var outputPaths = [String]()
    var runner: String?
    var status: String?
    var targetLabel = ""

    while !reader.isAtEnd {
      let field = try reader.readField()
      switch field.number {
      case 1:
        try field.require(.lengthDelimited)
        let argument = try reader.readString()
        if arguments.count < limits.command.maximumArgumentCount {
          arguments.append(argument)
        } else {
          commandDisplayExceededLimits = true
        }
      case 6:
        try field.require(.lengthDelimited)
        guard outputPaths.count < limits.command.maximumArgumentCount else {
          throw BazelExecutionLogError.malformedCompactLog
        }
        outputPaths.append(
          try parseOutput(
            reader.readLengthDelimited(maximumBytes: limits.maximumLineBytes),
            references: references
          )
        )
      case 7:
        try field.require(.lengthDelimited)
        targetLabel = try reader.readString()
      case 8:
        try field.require(.lengthDelimited)
        mnemonic = nonEmpty(try reader.readString())
      case 9:
        try field.require(.varint)
        exitCode = Int(Int32(truncatingIfNeeded: try reader.readVarint()))
      case 10:
        try field.require(.lengthDelimited)
        status = nonEmpty(try reader.readString())
      case 11:
        try field.require(.lengthDelimited)
        runner = nonEmpty(try reader.readString())
      case 12:
        try field.require(.varint)
        cacheHit = try reader.readVarint() != 0
      default:
        try reader.skip(field.wireType)
      }
    }

    let normalizedRunner = runner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let runnerReportsCacheHit =
      normalizedRunner == "disk cache hit"
      || normalizedRunner == "remote cache hit"
    guard cacheHit == runnerReportsCacheHit else {
      throw BazelExecutionLogError.malformedCompactLog
    }

    return BazelExecutionRecord(
      cacheHit: cacheHit,
      commandLineDisplayString: commandDisplayExceededLimits
        ? BazelCommandDisplay.omittedPlaceholder
        : BazelCommandDisplay.sanitize(arguments, limits: limits.command),
      exitCode: exitCode,
      listedOutputs: outputPaths,
      mnemonic: mnemonic,
      runner: runner,
      status: status,
      targetLabel: targetLabel
    )
  }

  private static func parseOutput(
    _ data: Data,
    references: [UInt32: CompactReference]
  ) throws -> String {
    var reader = ProtoReader(data)
    var output: CompactOutput?
    while !reader.isAtEnd {
      let field = try reader.readField()
      switch field.number {
      case 4:
        try field.require(.lengthDelimited)
        output = .invalidPath(try reader.readString())
      case 5:
        try field.require(.varint)
        output = .identifier(try reader.readUInt32())
      default:
        try reader.skip(field.wireType)
      }
    }
    guard let output else { throw BazelExecutionLogError.malformedCompactLog }
    switch output {
    case .invalidPath(let path):
      guard !path.isEmpty else { throw BazelExecutionLogError.malformedCompactLog }
      return path
    case .identifier(let identifier):
      guard let reference = references[identifier] else {
        throw BazelExecutionLogError.missingCompactOutputReference(identifier)
      }
      guard reference.kind != .other, let path = reference.path else {
        throw BazelExecutionLogError.wrongCompactOutputReference(identifier)
      }
      return path
    }
  }

  /// Compact symlink actions are non-spawn actions. Validate their narrow schema, but do not
  /// present them as executed spawns or claim cache/execution provenance for them.
  private static func validateSymlinkAction(_ data: Data) throws {
    var reader = ProtoReader(data)
    while !reader.isAtEnd {
      let field = try reader.readField()
      if (1...4).contains(field.number) {
        try field.require(.lengthDelimited)
        _ = try reader.readString()
      } else {
        try reader.skip(field.wireType)
      }
    }
  }
}

private enum CompactPayload {
  case other
  case reference(CompactReference)
  case spawn(BazelExecutionRecord)
}

private struct CompactReference {
  enum Kind {
    case directory
    case file
    case other
    case unresolvedSymlink
  }

  let kind: Kind
  let path: String?
}

private enum CompactOutput {
  case identifier(UInt32)
  case invalidPath(String)
}

private struct ProtoField {
  enum WireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
  }

  let number: Int
  let wireType: WireType

  func require(_ expected: WireType) throws {
    guard wireType == expected else { throw BazelExecutionLogError.malformedCompactLog }
  }
}

private struct ProtoReader {
  private let data: Data
  private var index: Data.Index

  init(_ data: Data) {
    self.data = data
    index = data.startIndex
  }

  var isAtEnd: Bool { index == data.endIndex }

  mutating func readField() throws -> ProtoField {
    let tag = try readVarint()
    guard tag != 0,
      tag >> 3 <= 536_870_911,
      let wireType = ProtoField.WireType(rawValue: tag & 0x7)
    else { throw BazelExecutionLogError.malformedCompactLog }
    return ProtoField(number: Int(tag >> 3), wireType: wireType)
  }

  mutating func readUInt32() throws -> UInt32 {
    let value = try readVarint()
    guard value <= UInt32.max else { throw BazelExecutionLogError.malformedCompactLog }
    return UInt32(value)
  }

  mutating func readVarint() throws -> UInt64 {
    var value: UInt64 = 0
    for byteIndex in 0..<10 {
      guard index < data.endIndex else { throw BazelExecutionLogError.malformedCompactLog }
      let byte = data[index]
      index += 1
      if byteIndex == 9, byte > 1 {
        throw BazelExecutionLogError.malformedCompactLog
      }
      value |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
      if byte & 0x80 == 0 { return value }
    }
    throw BazelExecutionLogError.malformedCompactLog
  }

  mutating func readLengthDelimited(maximumBytes: Int = Int.max) throws -> Data {
    let rawCount = try readVarint()
    guard rawCount <= UInt64(maximumBytes), rawCount <= UInt64(data.endIndex - index) else {
      if rawCount > UInt64(maximumBytes) {
        throw BazelExecutionLogError.lineLimitExceeded(maximumBytes)
      }
      throw BazelExecutionLogError.malformedCompactLog
    }
    let count = Int(rawCount)
    let end = index + count
    let result = data.subdata(in: index..<end)
    index = end
    return result
  }

  mutating func readString() throws -> String {
    let bytes = try readLengthDelimited()
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw BazelExecutionLogError.malformedCompactLog
    }
    return string
  }

  mutating func skip(_ wireType: ProtoField.WireType) throws {
    switch wireType {
    case .varint:
      _ = try readVarint()
    case .fixed64:
      try advance(8)
    case .lengthDelimited:
      _ = try readLengthDelimited()
    case .fixed32:
      try advance(4)
    }
  }

  private mutating func advance(_ count: Int) throws {
    guard count <= data.endIndex - index else {
      throw BazelExecutionLogError.malformedCompactLog
    }
    index += count
  }
}

private func nonEmpty(_ value: String) -> String? {
  value.isEmpty ? nil : value
}
