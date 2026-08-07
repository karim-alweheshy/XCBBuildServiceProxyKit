import CryptoKit
import Darwin
import Foundation

public enum BuildServiceFrameDirection: String, Codable, Sendable {
  case clientToService = "client_to_service"
  case serviceToClient = "service_to_client"
}

public enum BuildServiceFrameRelayError: LocalizedError, Equatable {
  case truncatedHeader(actualBytes: Int)
  case payloadTooLarge(UInt32)
  case truncatedPayload(expectedBytes: UInt32, actualBytes: UInt32)
  case invalidReadCount(Int)
  case invalidWriteCount(Int)
  case zeroLengthWrite
  case metadataFileAlreadyExists(String)
  case metadataFileCreationFailed(String, Int32)
  case metadataFilePermissionFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .truncatedHeader(let actualBytes):
      return "Build-service frame header was truncated after \(actualBytes) of 12 bytes."
    case .payloadTooLarge(let length):
      return "Build-service frame payload length \(length) exceeds Int32.max."
    case .truncatedPayload(let expectedBytes, let actualBytes):
      return
        "Build-service frame payload was truncated after \(actualBytes) of \(expectedBytes) bytes."
    case .invalidReadCount(let count):
      return "Build-service frame source returned invalid read count \(count)."
    case .invalidWriteCount(let count):
      return "Build-service frame destination returned invalid write count \(count)."
    case .zeroLengthWrite:
      return "Build-service frame destination returned a zero-length write."
    case .metadataFileAlreadyExists(let path):
      return "Build-service metadata destination already exists: \(path)"
    case .metadataFileCreationFailed(let path, let errorNumber):
      return
        "Build-service metadata destination could not be created: \(path) (errno \(errorNumber))."
    case .metadataFilePermissionFailed(let errorNumber):
      return
        "Build-service metadata permissions could not be restricted to 0600 (errno \(errorNumber))."
    }
  }
}

public struct BuildServiceFrameMetadata: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sequence: UInt64
  public let directionSequence: UInt64
  public let direction: BuildServiceFrameDirection
  public let channel: UInt64
  public let payloadLength: UInt32
  public let messageName: String?
  public let payloadSHA256: String
}

/// Writes one metadata-only JSON object per completed frame.
///
/// The destination is created exclusively with mode 0600. Existing paths are
/// rejected so a capture cannot overwrite a file or follow a leaf symlink.
public final class BuildServiceFrameMetadataRecorder: @unchecked Sendable {
  private let descriptor: Int32
  private let lock = NSLock()
  private var nextSequence: UInt64 = 1

  public init(fileURL: URL) throws {
    let path = fileURL.path
    let openedDescriptor = path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard openedDescriptor >= 0 else {
      if errno == EEXIST {
        throw BuildServiceFrameRelayError.metadataFileAlreadyExists(path)
      }
      throw BuildServiceFrameRelayError.metadataFileCreationFailed(path, errno)
    }
    guard fchmod(openedDescriptor, S_IRUSR | S_IWUSR) == 0 else {
      let permissionError = errno
      Darwin.close(openedDescriptor)
      path.withCString { _ = Darwin.unlink($0) }
      throw BuildServiceFrameRelayError.metadataFilePermissionFailed(permissionError)
    }
    descriptor = openedDescriptor
  }

  deinit {
    Darwin.close(descriptor)
  }

  fileprivate func record(
    direction: BuildServiceFrameDirection,
    directionSequence: UInt64,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?,
    payloadSHA256: String
  ) throws {
    try lock.withLock {
      let metadata = BuildServiceFrameMetadata(
        schemaVersion: 1,
        sequence: nextSequence,
        directionSequence: directionSequence,
        direction: direction,
        channel: channel,
        payloadLength: payloadLength,
        messageName: messageName,
        payloadSHA256: payloadSHA256
      )
      nextSequence += 1

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(metadata)
      line.append(0x0A)
      try line.withUnsafeBytes { bytes in
        try FileDescriptorFrameWriter(descriptor: descriptor).writeAll(bytes)
      }
    }
  }
}

protocol FrameByteReader: AnyObject {
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

protocol FrameByteWriter: AnyObject {
  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int
}

final class FileDescriptorFrameReader: FrameByteReader {
  private let descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    while true {
      let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
      if count >= 0 { return count }
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

final class FileDescriptorFrameWriter: FrameByteWriter {
  private let descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
  }

  func write(_ buffer: UnsafeRawBufferPointer) throws -> Int {
    while true {
      let count = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
      if count >= 0 { return count }
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

extension FrameByteWriter {
  fileprivate func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < buffer.count {
      let slice = UnsafeRawBufferPointer(rebasing: buffer[offset...])
      let count = try write(slice)
      guard count > 0 else {
        throw BuildServiceFrameRelayError.zeroLengthWrite
      }
      guard count <= slice.count else {
        throw BuildServiceFrameRelayError.invalidWriteCount(count)
      }
      offset += count
    }
  }
}

struct BuildServiceFramePumpSummary: Equatable {
  let frameCount: UInt64
  let byteCount: UInt64
}

final class BuildServiceFramePump {
  static let headerLength = 12
  static let maximumPayloadLength = UInt32(Int32.max)

  private let direction: BuildServiceFrameDirection
  private let reader: FrameByteReader
  private let writer: FrameByteWriter
  private let recorder: BuildServiceFrameMetadataRecorder?

  init(
    direction: BuildServiceFrameDirection,
    reader: FrameByteReader,
    writer: FrameByteWriter,
    recorder: BuildServiceFrameMetadataRecorder?
  ) {
    self.direction = direction
    self.reader = reader
    self.writer = writer
    self.recorder = recorder
  }

  func run() throws -> BuildServiceFramePumpSummary {
    var frameCount: UInt64 = 0
    var byteCount: UInt64 = 0
    var payloadBuffer: [UInt8]?

    while let header = try readHeader() {
      let channel = Self.decodeUInt64LittleEndian(header[0..<8])
      let payloadLength = Self.decodeUInt32LittleEndian(header[8..<12])
      guard payloadLength <= Self.maximumPayloadLength else {
        throw BuildServiceFrameRelayError.payloadTooLarge(payloadLength)
      }

      try header.withUnsafeBytes { try writer.writeAll($0) }

      var payloadBytesRead: UInt32 = 0
      var payloadHasher = SHA256()
      var messageNamePeeker = MessagePackMessageNamePeeker()
      if payloadLength > 0, payloadBuffer == nil {
        payloadBuffer = [UInt8](repeating: 0, count: 64 * 1024)
      }

      while payloadBytesRead < payloadLength {
        let remaining = Int(payloadLength - payloadBytesRead)
        let requestedCount = min(remaining, payloadBuffer!.count)
        let count = try payloadBuffer!.withUnsafeMutableBytes { bytes in
          try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<requestedCount]))
        }
        if count == 0 {
          throw BuildServiceFrameRelayError.truncatedPayload(
            expectedBytes: payloadLength,
            actualBytes: payloadBytesRead
          )
        }
        guard count > 0, count <= requestedCount else {
          throw BuildServiceFrameRelayError.invalidReadCount(count)
        }

        try payloadBuffer!.withUnsafeBytes { bytes in
          let chunk = UnsafeRawBufferPointer(rebasing: bytes[..<count])
          messageNamePeeker.consume(chunk)
          payloadHasher.update(data: Data(bytes: chunk.baseAddress!, count: chunk.count))
          try writer.writeAll(chunk)
        }
        payloadBytesRead += UInt32(count)
      }

      frameCount += 1
      byteCount += UInt64(Self.headerLength) + UInt64(payloadLength)
      try recorder?.record(
        direction: direction,
        directionSequence: frameCount,
        channel: channel,
        payloadLength: payloadLength,
        messageName: messageNamePeeker.messageName,
        payloadSHA256: payloadHasher.finalize().hexadecimalString
      )
    }

    return BuildServiceFramePumpSummary(frameCount: frameCount, byteCount: byteCount)
  }

  private func readHeader() throws -> [UInt8]? {
    var header = [UInt8](repeating: 0, count: Self.headerLength)
    var count = 0
    while count < header.count {
      let readCount = try header.withUnsafeMutableBytes { bytes in
        try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[count...]))
      }
      if readCount == 0 {
        if count == 0 { return nil }
        throw BuildServiceFrameRelayError.truncatedHeader(actualBytes: count)
      }
      guard readCount > 0, readCount <= header.count - count else {
        throw BuildServiceFrameRelayError.invalidReadCount(readCount)
      }
      count += readCount
    }
    return header
  }

  private static func decodeUInt64LittleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    bytes.enumerated().reduce(0) { result, element in
      result | (UInt64(element.element) << UInt64(element.offset * 8))
    }
  }

  private static func decodeUInt32LittleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.enumerated().reduce(0) { result, element in
      result | (UInt32(element.element) << UInt32(element.offset * 8))
    }
  }
}

private struct MessagePackMessageNamePeeker {
  private static let maximumMessageNameBytes = 256
  private static let maximumPrefixBytes = maximumMessageNameBytes + 5
  private var prefix: [UInt8] = []

  mutating func consume(_ bytes: UnsafeRawBufferPointer) {
    guard prefix.count < Self.maximumPrefixBytes else { return }
    let count = min(bytes.count, Self.maximumPrefixBytes - prefix.count)
    prefix.append(contentsOf: bytes.prefix(count))
  }

  var messageName: String? {
    guard let first = prefix.first else { return nil }

    let headerLength: Int
    let stringLength: Int
    switch first {
    case 0xA0...0xBF:
      headerLength = 1
      stringLength = Int(first & 0x1F)
    case 0xD9:
      guard prefix.count >= 2 else { return nil }
      headerLength = 2
      stringLength = Int(prefix[1])
    case 0xDA:
      guard prefix.count >= 3 else { return nil }
      headerLength = 3
      stringLength = Int(prefix[1]) << 8 | Int(prefix[2])
    case 0xDB:
      guard prefix.count >= 5 else { return nil }
      headerLength = 5
      let length =
        UInt32(prefix[1]) << 24 | UInt32(prefix[2]) << 16
        | UInt32(prefix[3]) << 8 | UInt32(prefix[4])
      guard length <= UInt32(Self.maximumMessageNameBytes) else { return nil }
      stringLength = Int(length)
    default:
      return nil
    }

    guard stringLength <= Self.maximumMessageNameBytes,
      prefix.count >= headerLength + stringLength
    else {
      return nil
    }
    let nameBytes = prefix[headerLength..<(headerLength + stringLength)]
    guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
      return nil
    }
    return String(bytes: nameBytes, encoding: .utf8)
  }
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
