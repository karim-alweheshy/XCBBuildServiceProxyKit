import Foundation
import XCTest

@testable import BazelProxyCore

final class BazelActionStartStreamTests: XCTestCase {
  func testStreamsValidatedStartBeforeProcessCompletion() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("action-starts.jsonl")
    let completion = ActionStartCompletionProbe()
    let collector = ActionStartCollector()
    let task = Task {
      try await BazelActionStartStreamFollower(pollInterval: .milliseconds(1)).follow(
        fileAt: url,
        processIsComplete: { await completion.value },
        onEvent: { await collector.append($0) }
      )
    }

    try actionStartLine(sequence: 1).write(to: url, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let observed = await waitForStart(in: collector)
    XCTAssertTrue(observed)
    let completedBeforeStart = await completion.value
    XCTAssertFalse(completedBeforeStart)
    await completion.complete()
    let validation = try await task.value

    XCTAssertEqual(validation?.starts.count, 1)
    XCTAssertEqual(validation?.starts[0].description, "Compiling Swift module App")
    XCTAssertEqual(validation?.starts[0].label, "//app:App")
  }

  func testMissingStreamIsBackwardCompatible() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let validation = try await BazelActionStartStreamFollower().follow(
      fileAt: root.appendingPathComponent("action-starts.jsonl"),
      processIsComplete: { true },
      onEvent: { _ in XCTFail("missing stream emitted an event") }
    )
    XCTAssertNil(validation)
  }

  func testRejectsMalformedSequenceTruncationAndSymlink() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let malformed = root.appendingPathComponent("malformed.jsonl")
    try actionStartLine(sequence: 2).write(to: malformed, atomically: false, encoding: .utf8)
    await assertThrowsErrorAsync(
      try await BazelActionStartStreamFollower().follow(
        fileAt: malformed,
        processIsComplete: { true },
        onEvent: { _ in }
      )
    ) { error in
      XCTAssertEqual(error as? BazelActionStartStreamError, .invalidSequence)
    }

    let truncated = root.appendingPathComponent("truncated.jsonl")
    try String(actionStartLine(sequence: 1).dropLast()).write(
      to: truncated,
      atomically: false,
      encoding: .utf8
    )
    await assertThrowsErrorAsync(
      try await BazelActionStartStreamFollower().follow(
        fileAt: truncated,
        processIsComplete: { true },
        onEvent: { _ in }
      )
    ) { error in
      XCTAssertEqual(error as? BazelActionStartStreamError, .malformedJSONLine)
    }

    let target = root.appendingPathComponent("target.jsonl")
    try actionStartLine(sequence: 1).write(to: target, atomically: false, encoding: .utf8)
    let link = root.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    await assertThrowsErrorAsync(
      try await BazelActionStartStreamFollower().follow(
        fileAt: link,
        processIsComplete: { true },
        onEvent: { _ in }
      )
    ) { error in
      XCTAssertEqual(error as? BazelActionStartStreamError, .unsafeFile(link.path))
    }
  }

  private func actionStartLine(sequence: Int) -> String {
    """
    {"configuration":"abc123","description":"Compiling Swift module App","executionPlatform":"@@platforms//host:host","label":"//app:App","mnemonic":"SwiftCompile","observedTimeUnixMicroseconds":1786438800000000,"schemaVersion":1,"sequence":\(sequence)}

    """
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BazelActionStartStreamTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func waitForStart(in collector: ActionStartCollector) async -> Bool {
    for _ in 0..<200 {
      if await collector.count > 0 { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private actor ActionStartCompletionProbe {
  private(set) var value = false

  func complete() {
    value = true
  }
}

private actor ActionStartCollector {
  private var starts = [BazelActionStarted]()

  var count: Int { starts.count }

  func append(_ start: BazelActionStarted) {
    starts.append(start)
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (any Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    errorHandler(error)
  }
}
