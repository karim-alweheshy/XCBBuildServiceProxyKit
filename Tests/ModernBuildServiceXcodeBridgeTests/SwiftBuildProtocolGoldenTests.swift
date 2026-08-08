import CryptoKit
import Foundation
import SWBProtocol
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class SwiftBuildProtocolGoldenTests: XCTestCase {
  private static let operationChannel: UInt64 = 100
  private static let operationID = -1
  private static let stableSignature = "rules_xcodeproj.bazel.v1://app:App"

  func testPinnedProtocolGoldenFixturesAreCompleteSafeAndByteIdentical() throws {
    let specifications = Self.makeSpecifications()
    let fixtureDirectory: URL
    if ProcessInfo.processInfo.environment["UPDATE_SWIFT_BUILD_PROTOCOL_GOLDENS"] == "1" {
      try Self.writeSourceFixtures(specifications)
      fixtureDirectory = Self.sourceFixtureDirectory
    } else {
      fixtureDirectory = try XCTUnwrap(
        Bundle.module.url(
          forResource: "SwiftBuildProtocol",
          withExtension: nil,
          subdirectory: "Fixtures"
        )
      )
    }

    let manifestURL = fixtureDirectory.appendingPathComponent("manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(GoldenManifest.self, from: manifestData)

    XCTAssertEqual(manifest.schemaVersion, 1)
    XCTAssertEqual(
      manifest.swiftBuildCommit,
      SwiftBuildProtocolCompatibility.swiftBuildCommit
    )
    XCTAssertEqual(
      manifest.xcodeProductBuildVersion,
      SwiftBuildProtocolCompatibility.xcodeProductBuildVersion
    )
    XCTAssertEqual(manifest.fixtures.map(\.file), specifications.map(\.file))

    for (entry, specification) in zip(manifest.fixtures, specifications) {
      XCTAssertEqual(entry.messageNames, specification.messageNames, entry.file)
      XCTAssertEqual(entry.channels, specification.channels, entry.file)
      XCTAssertEqual(entry.decodedSemanticFields, specification.semanticFields, entry.file)

      let fixtureURL = fixtureDirectory.appendingPathComponent(entry.file)
      let data = try Data(contentsOf: fixtureURL)
      XCTAssertEqual(data.count, entry.byteSize, entry.file)
      XCTAssertEqual(Self.sha256(data), entry.sha256, entry.file)
      XCTAssertEqual(data, specification.data, entry.file)

      let frames = try Self.parseFrames(data)
      XCTAssertEqual(frames.map(\.channel), entry.channels, entry.file)
      XCTAssertEqual(try frames.map(Self.messageName), entry.messageNames, entry.file)
      for frame in frames {
        let decoded = try SwiftBuildProtocolCodec.decodeIPCMessage(Array(frame.payload))
        XCTAssertEqual(
          SwiftBuildProtocolCodec.encode(decoded.message),
          Array(frame.payload),
          entry.file
        )
      }
      XCTAssertEqual(Self.join(frames), data, entry.file)
    }

    let allowedManifestText = try XCTUnwrap(String(data: manifestData, encoding: .utf8))
    XCTAssertFalse(
      allowedManifestText.contains(ProcessInfo.processInfo.environment["HOME"] ?? "\u{0}"))
    XCTAssertFalse(allowedManifestText.localizedCaseInsensitiveContains("password"))
    XCTAssertFalse(allowedManifestText.localizedCaseInsensitiveContains("secret"))
    XCTAssertFalse(allowedManifestText.localizedCaseInsensitiveContains("token"))
  }

  private static func makeSpecifications() -> [GoldenSpecification] {
    let target = SwiftBuildPresentedTarget(
      configurationIsDefault: false,
      configurationName: "Debug",
      guid: "TARGET-A",
      id: 1,
      name: "App",
      project: SwiftBuildPresentedProject(
        isNameUniqueInWorkspace: true,
        isPackage: false,
        name: "AppProject",
        path: "/workspace/App.xcodeproj"
      ),
      sdkCanonicalName: "iphonesimulator",
      type: .standard
    )
    let task = SwiftBuildPresentedTask(
      commandLineDisplayString: "bazel build //app:App",
      executionDescription: "Build with Bazel",
      id: 1,
      interestingPath: "/workspace/app/BUILD",
      parentID: nil,
      ruleInfo: "BazelBuild //app:App",
      serializedDiagnosticsPaths: ["/derived/app.dia"],
      stableSignature: stableSignature,
      targetID: 1,
      taskName: "Bazel"
    )

    let preparation = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodePreparationCompleted()
    )
    let operationStarted = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeOperationStarted(id: operationID)
    )
    let pathMap = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodePathMap(
        copied: ["/workspace/source": "/derived/copied"],
        generated: ["/workspace/generated": "/derived/generated"]
      )
    )
    let targetStarted = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeTargetStarted(target)
    )
    let taskStarted = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeTaskStarted(task)
    )
    let progress = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeProgressUpdated(
        targetName: "App",
        statusMessage: "Analyzing Bazel build",
        percentComplete: -1,
        showInLog: false
      )
    )
    let console = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeConsoleOutput(
        data: Array("synthetic output\n".utf8),
        taskID: 1,
        stableSignature: stableSignature
      )
    )
    let targetEnded = frame(
      channel: operationChannel,
      payload: SwiftBuildOperationPresenter.encodeTargetEnded(id: 1)
    )

    let diagnosticFrames = SwiftBuildPresentedDiagnosticKind.allCases.map { kind in
      frame(
        channel: operationChannel,
        payload: SwiftBuildOperationPresenter.encodeDiagnostic(
          SwiftBuildPresentedDiagnostic(
            context: .globalTask(taskID: 1, stableSignature: stableSignature),
            kind: kind,
            location: .path("/workspace/app/main.swift", line: 7, column: 3),
            message: "synthetic \(kind.fileComponent) diagnostic",
            traits: ["synthetic"]
          )
        )
      )
    }
    let taskEndedFrames = SwiftBuildPresentedTaskStatus.allCases.map { status in
      frame(
        channel: operationChannel,
        payload: SwiftBuildOperationPresenter.encodeTaskEnded(
          id: 1,
          stableSignature: stableSignature,
          status: status,
          signalled: status == .cancelled
        )
      )
    }
    let operationEndedFrames = SwiftBuildPresentedOperationStatus.allCases.map { status in
      frame(
        channel: operationChannel,
        payload: SwiftBuildOperationPresenter.encodeOperationEnded(
          id: operationID,
          status: status
        )
      )
    }

    var result: [GoldenSpecification] = [
      single(
        file: "request-build-start.frame",
        channel: 201,
        payload: SwiftBuildProtocolCodec.encode(
          BuildStartRequest(sessionHandle: "SESSION-1", id: operationID)
        ),
        fields: ["id": "-1", "sessionHandle": "SESSION-1"]
      ),
      single(
        file: "request-build-cancel.frame",
        channel: 202,
        payload: SwiftBuildProtocolCodec.encode(
          BuildCancelRequest(sessionHandle: "SESSION-1", id: operationID)
        ),
        fields: ["id": "-1", "sessionHandle": "SESSION-1"]
      ),
      single(
        file: "request-delete-session.frame",
        channel: 203,
        payload: SwiftBuildProtocolCodec.encode(
          DeleteSessionRequest(sessionHandle: "SESSION-1")
        ),
        fields: ["sessionHandle": "SESSION-1"]
      ),
      single(
        file: "response-build-created-negative-one.frame",
        channel: 201,
        payload: SwiftBuildOperationPresenter.encodeBuildCreated(id: operationID),
        fields: ["id": "-1"]
      ),
      single(
        file: "response-build-created-min-plus-one.frame",
        channel: 204,
        payload: SwiftBuildOperationPresenter.encodeBuildCreated(id: Int.min + 1),
        fields: ["id": String(Int.min + 1)]
      ),
      single(
        file: "response-void.frame",
        channel: 202,
        payload: SwiftBuildOperationPresenter.encodeVoidResponse(),
        fields: ["wireAlias": "VoidResponse=PingRequest"]
      ),
      single(
        file: "response-native-error.frame",
        channel: 205,
        payload: SwiftBuildProtocolCodec.encode(ErrorResponse("synthetic native failure")),
        fields: ["description": "synthetic native failure"]
      ),
      specification(
        file: "event-preparation.frame",
        frames: [preparation],
        fields: ["phase": "preparation-completed"]
      ),
      specification(
        file: "event-operation-started.frame",
        frames: [operationStarted],
        fields: ["id": "-1"]
      ),
      specification(
        file: "event-path-map.frame",
        frames: [pathMap],
        fields: ["copiedCount": "1", "generatedCount": "1"]
      ),
      specification(
        file: "event-target-started.frame",
        frames: [targetStarted],
        fields: ["guid": "TARGET-A", "id": "1", "name": "App"]
      ),
      specification(
        file: "event-task-started.frame",
        frames: [taskStarted],
        fields: ["id": "1", "stableSignature": stableSignature, "targetID": "1"]
      ),
      specification(
        file: "event-progress.frame",
        frames: [progress],
        fields: ["percentComplete": "-1", "showInLog": "false"]
      ),
      specification(
        file: "event-console.frame",
        frames: [console],
        fields: ["dataUTF8": "synthetic output\\n", "taskID": "1", "taskSignature": "nil"]
      ),
      specification(
        file: "event-target-ended.frame",
        frames: [targetEnded],
        fields: ["id": "1"]
      ),
    ]

    for (kind, diagnosticFrame) in zip(
      SwiftBuildPresentedDiagnosticKind.allCases,
      diagnosticFrames
    ) {
      result.append(
        specification(
          file: "event-diagnostic-\(kind.fileComponent).frame",
          frames: [diagnosticFrame],
          fields: ["kind": kind.fileComponent, "line": "7", "column": "3"]
        )
      )
    }
    for (status, endedFrame) in zip(SwiftBuildPresentedTaskStatus.allCases, taskEndedFrames) {
      result.append(
        specification(
          file: "event-task-ended-\(status.fileComponent).frame",
          frames: [endedFrame],
          fields: [
            "id": "1",
            "signalled": String(status == .cancelled),
            "status": status.fileComponent,
          ]
        )
      )
    }
    for (status, endedFrame) in zip(
      SwiftBuildPresentedOperationStatus.allCases,
      operationEndedFrames
    ) {
      result.append(
        specification(
          file: "event-operation-ended-\(status.fileComponent).frame",
          frames: [endedFrame],
          fields: ["id": "-1", "status": status.fileComponent]
        )
      )
    }

    let taskSucceeded = taskEndedFrames[SwiftBuildPresentedTaskStatus.succeeded.fixtureIndex]
    let taskFailed = taskEndedFrames[SwiftBuildPresentedTaskStatus.failed.fixtureIndex]
    let taskCancelled = taskEndedFrames[SwiftBuildPresentedTaskStatus.cancelled.fixtureIndex]
    let operationSucceeded =
      operationEndedFrames[SwiftBuildPresentedOperationStatus.succeeded.fixtureIndex]
    let operationFailed = operationEndedFrames[
      SwiftBuildPresentedOperationStatus.failed.fixtureIndex]
    let operationCancelled =
      operationEndedFrames[SwiftBuildPresentedOperationStatus.cancelled.fixtureIndex]
    let errorDiagnostic =
      diagnosticFrames[SwiftBuildPresentedDiagnosticKind.error.fixtureIndex]

    result.append(
      specification(
        file: "stream-success.frames",
        frames: [
          preparation,
          operationStarted,
          pathMap,
          targetStarted,
          taskStarted,
          progress,
          console,
          taskSucceeded,
          targetEnded,
          operationSucceeded,
        ],
        fields: ["frameCount": "10", "id": "-1", "result": "succeeded"]
      )
    )
    result.append(
      specification(
        file: "stream-failure.frames",
        frames: [errorDiagnostic, taskFailed, targetEnded, operationFailed],
        fields: ["frameCount": "4", "id": "-1", "result": "failed"]
      )
    )
    result.append(
      specification(
        file: "stream-cancel.frames",
        frames: [taskCancelled, targetEnded, operationCancelled],
        fields: ["frameCount": "3", "id": "-1", "result": "cancelled"]
      )
    )
    return result
  }

  private static func single(
    file: String,
    channel: UInt64,
    payload: [UInt8],
    fields: [String: String]
  ) -> GoldenSpecification {
    specification(
      file: file,
      frames: [frame(channel: channel, payload: payload)],
      fields: fields
    )
  }

  private static func specification(
    file: String,
    frames: [GoldenFrame],
    fields: [String: String]
  ) -> GoldenSpecification {
    GoldenSpecification(
      channels: frames.map(\.channel),
      data: join(frames),
      file: file,
      messageNames: try! frames.map(messageName),
      semanticFields: fields
    )
  }

  private static func frame(channel: UInt64, payload: [UInt8]) -> GoldenFrame {
    GoldenFrame(channel: channel, payload: Data(payload))
  }

  private static func join(_ frames: [GoldenFrame]) -> Data {
    frames.reduce(into: Data()) { data, frame in
      data.append(frame.encoded)
    }
  }

  private static func parseFrames(_ data: Data) throws -> [GoldenFrame] {
    var frames: [GoldenFrame] = []
    var offset = 0
    while offset < data.count {
      guard data.count - offset >= 12 else { throw GoldenError.truncatedHeader }
      let channel = decodeUInt64(data[offset..<(offset + 8)])
      let payloadSize = Int(decodeUInt32(data[(offset + 8)..<(offset + 12)]))
      let payloadStart = offset + 12
      let payloadEnd = payloadStart + payloadSize
      guard payloadEnd <= data.count else { throw GoldenError.truncatedPayload }
      frames.append(
        GoldenFrame(channel: channel, payload: Data(data[payloadStart..<payloadEnd]))
      )
      offset = payloadEnd
    }
    return frames
  }

  private static func messageName(_ frame: GoldenFrame) throws -> String {
    let message = try SwiftBuildProtocolCodec.decodeIPCMessage(Array(frame.payload))
    return type(of: message.message).name
  }

  private static func decodeUInt64(_ bytes: Data.SubSequence) -> UInt64 {
    bytes.enumerated().reduce(0) {
      $0 | (UInt64($1.element) << UInt64($1.offset * 8))
    }
  }

  private static func decodeUInt32(_ bytes: Data.SubSequence) -> UInt32 {
    bytes.enumerated().reduce(0) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeSourceFixtures(_ specifications: [GoldenSpecification]) throws {
    let sourceDirectory = sourceFixtureDirectory
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: true
    )

    for specification in specifications {
      try specification.data.write(
        to: sourceDirectory.appendingPathComponent(specification.file),
        options: .atomic
      )
    }

    let manifest = GoldenManifest(
      fixtures: specifications.map {
        GoldenManifest.Entry(
          byteSize: $0.data.count,
          channels: $0.channels,
          decodedSemanticFields: $0.semanticFields,
          file: $0.file,
          messageNames: $0.messageNames,
          sha256: sha256($0.data)
        )
      },
      schemaVersion: 1,
      swiftBuildCommit: SwiftBuildProtocolCompatibility.swiftBuildCommit,
      xcodeProductBuildVersion: SwiftBuildProtocolCompatibility.xcodeProductBuildVersion
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(manifest)
    data.append(0x0A)
    try data.write(
      to: sourceDirectory.appendingPathComponent("manifest.json"),
      options: .atomic
    )
  }

  private static var sourceFixtureDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/SwiftBuildProtocol", isDirectory: true)
  }
}

private struct GoldenFrame: Equatable {
  let channel: UInt64
  let payload: Data

  init(channel: UInt64, payload: Data) {
    self.channel = channel
    self.payload = payload
  }

  var encoded: Data {
    var channel = channel.littleEndian
    var length = UInt32(payload.count).littleEndian
    var result = withUnsafeBytes(of: &channel) { Data($0) }
    result.append(withUnsafeBytes(of: &length) { Data($0) })
    result.append(payload)
    return result
  }
}

private struct GoldenSpecification {
  let channels: [UInt64]
  let data: Data
  let file: String
  let messageNames: [String]
  let semanticFields: [String: String]
}

private struct GoldenManifest: Codable {
  struct Entry: Codable {
    let byteSize: Int
    let channels: [UInt64]
    let decodedSemanticFields: [String: String]
    let file: String
    let messageNames: [String]
    let sha256: String
  }

  let fixtures: [Entry]
  let schemaVersion: Int
  let swiftBuildCommit: String
  let xcodeProductBuildVersion: String
}

private enum GoldenError: Error {
  case truncatedHeader
  case truncatedPayload
}

extension SwiftBuildPresentedDiagnosticKind {
  fileprivate var fileComponent: String {
    switch self {
    case .error: "error"
    case .note: "note"
    case .remark: "remark"
    case .warning: "warning"
    }
  }

  fileprivate var fixtureIndex: Int {
    Self.allCases.firstIndex(of: self)!
  }
}

extension SwiftBuildPresentedTaskStatus {
  fileprivate var fileComponent: String {
    switch self {
    case .cancelled: "cancelled"
    case .failed: "failed"
    case .succeeded: "succeeded"
    }
  }

  fileprivate var fixtureIndex: Int {
    Self.allCases.firstIndex(of: self)!
  }
}

extension SwiftBuildPresentedOperationStatus {
  fileprivate var fileComponent: String {
    switch self {
    case .cancelled: "cancelled"
    case .failed: "failed"
    case .succeeded: "succeeded"
    }
  }

  fileprivate var fixtureIndex: Int {
    Self.allCases.firstIndex(of: self)!
  }
}
