import Foundation
import XCTest

@testable import BazelProxyCore

final class BEPStreamValidatorTests: XCTestCase {
  func testIncrementallyParsesAllowlistedEventsAndTerminalResult() throws {
    let lines = [
      #"{"progress":{"stderr":"\u001b[32m[1,217 / 1,504]\u001b[0m [Prepa] Compiling App.swift\n"}}"#,
      #"{"id":{"actionCompleted":{"configuration":"sim-arm64","label":"//app:App","primaryOutput":"bazel-out/App.app"}},"action":{"success":true,"type":"SwiftCompile"}}"#,
      #"{"id":{"targetCompleted":{"label":"//app:App"}},"completed":{"success":true}}"#,
      #"{"buildMetrics":{"actionSummary":{"actionsExecuted":"7"}}}"#,
      #"{"finished":{"overallSuccess":true}}"#,
    ]
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    var validator = try BEPStreamValidator()
    var events = [BEPEvent]()
    for chunk in data.chunks(of: 11) {
      events.append(contentsOf: try validator.consume(chunk))
    }
    let result = try validator.finish()

    XCTAssertTrue(
      events.contains(
        .progress(
          ProxyProgress(
            activity: "[Prepa] Compiling App.swift",
            completed: 1_217,
            source: .interactiveHint,
            total: 1_504
          )
        )
      )
    )
    XCTAssertTrue(events.contains(.reportedExecutedActionCount(7)))
    XCTAssertTrue(events.contains(.finished(succeeded: true)))
    XCTAssertTrue(
      events.contains(
        .actionCompleted(
          BEPActionCompleted(
            configuration: "sim-arm64",
            identity: "//app:App|bazel-out/App.app|sim-arm64",
            label: "//app:App",
            mnemonic: "SwiftCompile",
            primaryOutput: "bazel-out/App.app",
            succeeded: true
          )
        )
      )
    )
    XCTAssertEqual(
      result.completedActionIDs,
      ["//app:App|bazel-out/App.app|sim-arm64"]
    )
    XCTAssertEqual(result.reportedExecutedActionCount, 7)
    XCTAssertTrue(result.succeeded)
  }

  func testEnvironmentBearingEventProducesNoRetainedPayload() throws {
    let secretMarker = "do-not-retain-test-value"
    let line =
      #"{"id":{"unstructuredCommandLine":{}},"unstructuredCommandLine":{"args":["--client_env=PRIVATE_TOKEN="#
      + secretMarker + #""]}}"#
    var validator = try BEPStreamValidator()
    XCTAssertEqual(try validator.consume(Data((line + "\n").utf8)), [])
    _ = try validator.consume(Data(#"{"finished":{"overallSuccess":true}}"#.utf8))
    let result = try validator.finish()
    XCTAssertTrue(result.succeeded)
    XCTAssertFalse(String(describing: result).contains(secretMarker))
  }

  func testAcceptsBoundedLargeIgnoredNamedSetEvent() throws {
    let path = String(repeating: "a", count: 512)
    let files = (0..<4_000)
      .map { #"{"name":""# + path + "\($0)\"}" }
      .joined(separator: ",")
    let namedSet =
      #"{"id":{"namedSet":{"id":"large"}},"namedSetOfFiles":{"files":["#
      + files + "]}}\n"
    let data = Data(namedSet.utf8)
    XCTAssertGreaterThan(data.count, 1024 * 1024)
    XCTAssertLessThan(data.count, BEPStreamLimits().maximumLineBytes)
    var validator = try BEPStreamValidator()
    var events = [BEPEvent]()

    for chunk in data.chunks(of: 64 * 1024) {
      events.append(contentsOf: try validator.consume(chunk))
    }
    events.append(
      contentsOf: try validator.consume(
        Data((#"{"finished":{"overallSuccess":true}}"# + "\n").utf8)
      )
    )

    XCTAssertEqual(events, [.finished(succeeded: true)])
    XCTAssertTrue(try validator.finish().succeeded)
  }

  func testRejectsMalformedTruncatedAndOversizedInput() throws {
    var malformed = try BEPStreamValidator()
    XCTAssertThrowsError(try malformed.consume(Data("not-json\n".utf8))) { error in
      XCTAssertEqual(error as? BEPStreamError, .malformedJSONLine)
    }

    var truncated = try BEPStreamValidator()
    _ = try truncated.consume(Data(#"{"finished":{"overallSuccess":tru"#.utf8))
    XCTAssertThrowsError(try truncated.finish()) { error in
      XCTAssertEqual(error as? BEPStreamError, .malformedJSONLine)
    }

    let limits = BEPStreamLimits(maximumFileBytes: 64, maximumLineBytes: 32)
    var oversizedLine = try BEPStreamValidator(limits: limits)
    XCTAssertThrowsError(
      try oversizedLine.consume(Data(String(repeating: "x", count: 33).utf8))
    ) { error in
      XCTAssertEqual(error as? BEPStreamError, .lineLimitExceeded(32))
    }

    var oversizedFile = try BEPStreamValidator(limits: limits)
    _ = try oversizedFile.consume(Data("{}\n".utf8))
    XCTAssertThrowsError(
      try oversizedFile.consume(Data(String(repeating: " ", count: 62).utf8))
    ) { error in
      XCTAssertEqual(error as? BEPStreamError, .fileLimitExceeded(64))
    }

    var booleanCount = try BEPStreamValidator()
    XCTAssertThrowsError(
      try booleanCount.consume(
        Data((#"{"buildMetrics":{"actionSummary":{"actionsExecuted":true}}}"# + "\n").utf8)
      )
    ) { error in
      XCTAssertEqual(
        error as? BEPStreamError,
        .invalidCount("buildMetrics.actionSummary.actionsExecuted")
      )
    }
  }

  func testRejectsMissingDuplicateAndContradictoryTerminalState() throws {
    var missing = try BEPStreamValidator()
    _ = try missing.consume(Data("{}\n".utf8))
    XCTAssertThrowsError(try missing.finish()) { error in
      XCTAssertEqual(error as? BEPStreamError, .missingFinishedEvent)
    }

    var duplicate = try BEPStreamValidator()
    XCTAssertThrowsError(
      try duplicate.consume(
        Data(
          "{\"finished\":{\"overallSuccess\":true}}\n"
            .appending("{\"finished\":{\"overallSuccess\":true}}\n").utf8
        )
      )
    ) { error in
      XCTAssertEqual(error as? BEPStreamError, .duplicateFinishedEvent)
    }

    var contradictory = try BEPStreamValidator()
    _ = try contradictory.consume(
      Data(
        "{\"id\":{\"targetCompleted\":{\"label\":\"//app:App\"}},"
          .appending("\"completed\":{\"success\":false}}\n")
          .appending("{\"finished\":{\"overallSuccess\":true}}\n").utf8
      )
    )
    XCTAssertThrowsError(try contradictory.finish()) { error in
      XCTAssertEqual(error as? BEPStreamError, .contradictoryTerminalResult)
    }
  }

  func testRejectsDuplicateActionIdentity() throws {
    let line =
      #"{"id":{"actionCompleted":{"configuration":"sim","label":"//app:App","primaryOutput":"App.app"}},"action":{"success":true}}"#
    var validator = try BEPStreamValidator()
    _ = try validator.consume(Data((line + "\n").utf8))
    XCTAssertThrowsError(try validator.consume(Data((line + "\n").utf8))) { error in
      XCTAssertEqual(
        error as? BEPStreamError,
        .duplicateActionIdentity("//app:App|App.app|sim")
      )
    }
  }

  func testParsesProtocolNeutralDiagnostics() {
    XCTAssertEqual(
      DiagnosticParser.parse(
        line: "/tmp/App.swift:12:8: error: use of unresolved identifier 'broken'"
      ),
      ProxyDiagnostic(
        column: 8,
        line: 12,
        message: "use of unresolved identifier 'broken'",
        path: "/tmp/App.swift",
        severity: .error
      )
    )
    XCTAssertEqual(
      DiagnosticParser.parse(line: "WARNING: cache is unavailable"),
      ProxyDiagnostic(
        column: nil,
        line: nil,
        message: "cache is unavailable",
        path: nil,
        severity: .warning
      )
    )
  }

  func testProjectsValidatedBEPEventsWithoutProtocolTypes() {
    XCTAssertEqual(
      ProxyEventProjection.project(.reportedExecutedActionCount(4)),
      [
        .progress(
          ProxyProgress(completed: 4, source: .reportedExecutedActions, total: nil)
        )
      ]
    )
    XCTAssertEqual(
      ProxyEventProjection.project(.finished(succeeded: false)),
      [
        .lifecycle(.operationStarted),
        .lifecycle(.operationEnded(.failed)),
      ]
    )
    XCTAssertEqual(
      ProxyEventProjection.project(
        .actionCompleted(identity: "//app:App|App.app|sim", succeeded: true)
      ),
      [
        .lifecycle(.taskStarted(entityID: "//app:App|App.app|sim")),
        .lifecycle(
          .taskEnded(
            entityID: "//app:App|App.app|sim",
            status: .succeeded,
            signalled: false
          )
        ),
      ]
    )
    XCTAssertEqual(
      ProxyEventProjection.project(
        .actionCompleted(identity: "//app:App|App.app|sim", succeeded: nil)
      ),
      []
    )
  }

  func testDescriptorBoundedFileValidationCapturesFinalUnterminatedEventAndRejectsSymlink() throws {
    let fixture = try ManifestFixture()
    let bepURL = fixture.rootURL.appendingPathComponent("events.jsonl")
    try Data(#"{"finished":{"overallSuccess":true}}"#.utf8).write(to: bepURL)

    let validation = try BEPStreamValidator.validate(fileAt: bepURL)
    XCTAssertEqual(validation.events, [.finished(succeeded: true)])
    XCTAssertTrue(validation.result.succeeded)

    let linkedURL = fixture.rootURL.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: bepURL)
    XCTAssertThrowsError(try BEPStreamValidator.validate(fileAt: linkedURL)) { error in
      XCTAssertEqual(error as? BEPStreamError, .unsafeFile(linkedURL.path))
    }
  }

  func testParsesOptInRealBazelNineBEP() throws {
    guard let path = ProcessInfo.processInfo.environment["BAZEL_PROXY_REAL_BEP_PATH"] else {
      throw XCTSkip("Set BAZEL_PROXY_REAL_BEP_PATH to a completed Bazel 9 JSON BEP file")
    }

    let validation = try BEPStreamValidator.validate(fileAt: URL(fileURLWithPath: path))
    XCTAssertTrue(validation.result.succeeded)
    let reportedActionCount = try XCTUnwrap(validation.result.reportedExecutedActionCount)
    XCTAssertGreaterThanOrEqual(reportedActionCount, 0)
    XCTAssertEqual(
      validation.events.filter {
        if case .finished(succeeded: true) = $0 { return true }
        return false
      }.count,
      1
    )
    XCTAssertTrue(
      validation.events.contains {
        if case .targetCompleted(label: _, succeeded: true) = $0 { return true }
        return false
      }
    )
    for identity in validation.result.completedActionIDs {
      let components = identity.split(separator: "|", omittingEmptySubsequences: false)
      XCTAssertEqual(components.count, 3)
      XCTAssertTrue(components.allSatisfy { !$0.isEmpty })
    }
  }
}

extension Data {
  fileprivate func chunks(of count: Int) -> [Data] {
    stride(from: startIndex, to: endIndex, by: count).map { start in
      let end = Swift.min(start + count, endIndex)
      return self[start..<end]
    }
  }
}
