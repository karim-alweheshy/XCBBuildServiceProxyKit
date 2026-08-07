import CryptoKit
import Darwin
import Foundation

public enum EvaluatedSettingsProbeStatus: String, Codable, Sendable {
  case succeeded
  case failed
  case notRun = "not_run"
}

public enum EvaluatedSettingsProbeFailureCode: String, Codable, Sendable {
  case capturedPayloadTooLarge = "captured_payload_too_large"
  case createBuildDecodeFailed = "create_build_decode_failed"
  case invalidManifest = "invalid_manifest"
  case missingRequiredPlanRole = "missing_required_plan_role"
  case multiTargetSharedValueDisagreement = "multi_target_shared_value_disagreement"
  case noConfiguredTargets = "no_configured_targets"
  case previewStateDisagreement = "preview_state_disagreement"
  case requestSendFailed = "request_send_failed"
  case responseDecodeFailed = "response_decode_failed"
  case responseShapeMismatch = "response_shape_mismatch"
  case timeout
  case unexpectedSameChannelTraffic = "unexpected_same_channel_traffic"
}

public struct EvaluatedSettingsProbeValueMetadata: Codable, Equatable, Sendable {
  public let key: String
  public let present: Bool
  public let valueByteLength: Int
  public let valueSHA256: String
}

public struct EvaluatedSettingsProbeTargetReport: Codable, Equatable, Sendable {
  public let targetIndex: Int
  public let settings: [EvaluatedSettingsProbeValueMetadata]
}

public struct EvaluatedSettingsProbeReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: EvaluatedSettingsProbeStatus
  public let failureCodes: [EvaluatedSettingsProbeFailureCode]
  public let targetCount: Int
  public let targets: [EvaluatedSettingsProbeTargetReport]
}

enum EvaluatedSettingsProbeReportWriterError: Error, Equatable {
  case destinationAlreadyExists
  case destinationCreationFailed(Int32)
  case destinationPermissionFailed(Int32)
  case destinationWriteFailed(Int32)
  case reportAlreadyWritten
  case zeroLengthWrite
}

final class EvaluatedSettingsProbeReportWriter {
  private let descriptor: Int32
  private let lock = NSLock()
  private var hasWritten = false

  init(fileURL: URL) throws {
    let descriptor = fileURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw EvaluatedSettingsProbeReportWriterError.destinationAlreadyExists
      }
      throw EvaluatedSettingsProbeReportWriterError.destinationCreationFailed(errno)
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      let permissionError = errno
      Darwin.close(descriptor)
      fileURL.path.withCString { _ = Darwin.unlink($0) }
      throw EvaluatedSettingsProbeReportWriterError.destinationPermissionFailed(permissionError)
    }
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
  }

  func write(_ report: EvaluatedSettingsProbeReport) throws {
    try lock.withLock {
      guard !hasWritten else {
        throw EvaluatedSettingsProbeReportWriterError.reportAlreadyWritten
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var bytes = try encoder.encode(report)
      bytes.append(0x0A)
      try bytes.withUnsafeBytes(writeAll)
      hasWritten = true
    }
  }

  private func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor,
        bytes.baseAddress!.advanced(by: offset),
        bytes.count - offset
      )
      if count < 0 {
        if errno == EINTR { continue }
        throw EvaluatedSettingsProbeReportWriterError.destinationWriteFailed(errno)
      }
      guard count > 0 else {
        throw EvaluatedSettingsProbeReportWriterError.zeroLengthWrite
      }
      offset += count
    }
  }
}

extension EvaluatedSettingsProbeValueMetadata {
  init(key: String, value: String) {
    let bytes = Data(value.utf8)
    self.init(
      key: key,
      present: !bytes.isEmpty,
      valueByteLength: bytes.count,
      valueSHA256: SHA256.hash(data: bytes).hexadecimalString
    )
  }
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
