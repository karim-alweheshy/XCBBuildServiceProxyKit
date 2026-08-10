import Foundation
import XCTest

@testable import BazelProxyCore

final class BEPStreamFollowerTests: XCTestCase {
  func testRejectsPathReplacementAfterOpeningStream() async throws {
    let fixture = try FollowerFixture()
    defer { fixture.remove() }
    let originalURL = fixture.rootURL.appendingPathComponent("build-events.jsonl")
    let movedURL = fixture.rootURL.appendingPathComponent("opened-build-events.jsonl")
    try Self.actionLine.write(to: originalURL, atomically: false, encoding: .utf8)
    let completion = FollowerCompletionSignal()
    let collector = FollowerEventCollector()
    let task = Task {
      try await BEPStreamFollower().follow(
        fileAt: originalURL,
        processIsComplete: { await completion.isComplete }
      ) { event in
        await collector.append(event)
      }
    }

    let actionArrived = await waitForAction(in: collector)
    XCTAssertTrue(actionArrived, "follower did not open the original file")
    try FileManager.default.moveItem(at: originalURL, to: movedURL)
    try Self.finishedLine.write(to: originalURL, atomically: false, encoding: .utf8)
    await completion.markComplete()

    do {
      _ = try await task.value
      XCTFail("replacing the published BEP path must fail closed")
    } catch let error as BEPStreamError {
      XCTAssertEqual(error, .unsafeFile(originalURL.path))
    }
  }

  func testRejectsSymlinkBeforeOpeningStream() async throws {
    let fixture = try FollowerFixture()
    defer { fixture.remove() }
    let targetURL = fixture.rootURL.appendingPathComponent("real-build-events.jsonl")
    let linkedURL = fixture.rootURL.appendingPathComponent("linked-build-events.jsonl")
    try Self.finishedLine.write(to: targetURL, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: targetURL)

    do {
      _ = try await BEPStreamFollower().follow(
        fileAt: linkedURL,
        processIsComplete: { true },
        onEvent: { _ in }
      )
      XCTFail("a symlinked BEP must fail closed")
    } catch let error as BEPStreamError {
      XCTAssertEqual(error, .unsafeFile(linkedURL.path))
    }
  }

  func testRejectsMalformedBytesBeforeProcessCompletion() async throws {
    let fixture = try FollowerFixture()
    defer { fixture.remove() }
    let url = fixture.rootURL.appendingPathComponent("build-events.jsonl")
    try "not-json\n".write(to: url, atomically: false, encoding: .utf8)

    do {
      _ = try await BEPStreamFollower().follow(
        fileAt: url,
        processIsComplete: { false },
        onEvent: { _ in }
      )
      XCTFail("malformed bytes must fail before the process exits")
    } catch let error as BEPStreamError {
      XCTAssertEqual(error, .malformedJSONLine)
    }
  }

  func testCancellationStopsWaitingForMissingStream() async throws {
    let fixture = try FollowerFixture()
    defer { fixture.remove() }
    let url = fixture.rootURL.appendingPathComponent("missing-build-events.jsonl")
    let task = Task {
      try await BEPStreamFollower().follow(
        fileAt: url,
        processIsComplete: { false }
      ) { _ in }
    }

    try await Task.sleep(for: .milliseconds(30))
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("cancellation must stop the follower")
    } catch is CancellationError {
    }
  }

  private static let actionLine =
    """
    {"id":{"actionCompleted":{"configuration":"sim-arm64","label":"//app:App","primaryOutput":"bazel-out/products/App.app"}},"action":{"success":true,"type":"BundleTreeApp","commandLine":["assemble-app"]}}
    """ + "\n"

  private static let finishedLine =
    """
    {"finished":{"overallSuccess":true}}
    """ + "\n"

  private func waitForAction(in collector: FollowerEventCollector) async -> Bool {
    for _ in 0..<100 {
      if await collector.containsAction { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor FollowerCompletionSignal {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}

private actor FollowerEventCollector {
  private var events = [BEPEvent]()

  var containsAction: Bool {
    events.contains { event in
      guard case .actionCompleted = event else { return false }
      return true
    }
  }

  func append(_ event: BEPEvent) {
    events.append(event)
  }
}

private struct FollowerFixture {
  let rootURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BEPStreamFollowerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
