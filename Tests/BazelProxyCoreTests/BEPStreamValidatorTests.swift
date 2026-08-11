import Foundation
import XCTest

@testable import BazelProxyCore

final class BEPStreamValidatorTests: XCTestCase {
  func testProductionDefaultsBoundBEPFileAndLineSizes() {
    let limits = BEPStreamLimits()

    XCTAssertEqual(limits.maximumFileBytes, 512 * 1024 * 1024)
    XCTAssertEqual(limits.maximumLineBytes, 4 * 1024 * 1024)
  }

  func testIncrementallyParsesAllowlistedEventsAndTerminalResult() throws {
    let lines = [
      #"{"started":{"uuid":"49603573-5756-46e6-bdb8-fed092d6629d","buildToolVersion":"9.1.1rc1"}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"https://build.example/invocation/"}]}}]}}"#,
      #"{"buildMetadata":{"metadata":{"REMOTE_CACHE":"BuildBuddy","PRIVATE_TOKEN":"do-not-retain"}}}"#,
      #"{"progress":{"stderr":"\u001b[32m[1,217 / 1,504]\u001b[0m [Prepa] Compiling App.swift\n"}}"#,
      #"{"id":{"actionCompleted":{"configuration":"sim-arm64","label":"//app:App","primaryOutput":"bazel-out/App.app"}},"action":{"success":true,"type":"SwiftCompile","startTime":"2026-08-11T00:28:11.517582Z","endTime":"2026-08-11T00:29:01.915582Z"}}"#,
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
    XCTAssertTrue(
      events.contains(
        .buildMetadata(
          .invocation(
            buildToolVersion: "9.1.1rc1",
            id: "49603573-5756-46e6-bdb8-fed092d6629d"
          )
        )
      )
    )
    XCTAssertTrue(
      events.contains(
        .buildMetadata(
          .resultsURL(
            "https://build.example/invocation/49603573-5756-46e6-bdb8-fed092d6629d"
          )
        )
      )
    )
    XCTAssertTrue(events.contains(.buildMetadata(.remoteCache("BuildBuddy"))))
    XCTAssertFalse(String(describing: events).contains("do-not-retain"))
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
            succeeded: true,
            timing: BazelExecutionTiming(
              startTimeUnixMicroseconds: 1_786_408_091_517_582,
              durationMicroseconds: 50_398_000
            )
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

  func testActionTimingAcceptsCanonicalPrecisionAndRejectsInvalidIntervals() throws {
    func actionLine(start: String?, end: String?) -> Data {
      var timing = ""
      if let start { timing += ",\"startTime\":\"" + start + "\"" }
      if let end { timing += ",\"endTime\":\"" + end + "\"" }
      return Data(
        (#"{"id":{"actionCompleted":{"configuration":"sim","label":"//app:App","primaryOutput":"out"}},"action":{"success":true"#
          + timing + "}}\n").utf8
      )
    }

    var noFraction = try BEPStreamValidator()
    XCTAssertEqual(
      try noFraction.consume(
        actionLine(start: "2026-08-11T00:28:11Z", end: "2026-08-11T00:28:12Z")
      ).first,
      .actionCompleted(
        BEPActionCompleted(
          configuration: "sim",
          identity: "//app:App|out|sim",
          label: "//app:App",
          mnemonic: nil,
          primaryOutput: "out",
          succeeded: true,
          timing: BazelExecutionTiming(
            startTimeUnixMicroseconds: 1_786_408_091_000_000,
            durationMicroseconds: 1_000_000
          )
        )
      )
    )

    var nanoseconds = try BEPStreamValidator()
    guard
      case .actionCompleted(let completed) = try XCTUnwrap(
        nanoseconds.consume(
          actionLine(
            start: "2026-08-11T00:28:11.123456789Z",
            end: "2026-08-11T00:28:12.123456999Z"
          )
        ).first
      )
    else {
      return XCTFail("Expected an action-completed event")
    }
    XCTAssertEqual(completed.timing?.durationMicroseconds, 1_000_000)

    for invalid in [
      actionLine(start: "2026-08-11T00:28:11Z", end: nil),
      actionLine(start: "2026-02-30T00:28:11Z", end: "2026-03-01T00:28:11Z"),
      actionLine(
        start: "2026-08-11T00:28:12.000001Z",
        end: "2026-08-11T00:28:12Z"
      ),
    ] {
      var validator = try BEPStreamValidator()
      XCTAssertThrowsError(try validator.consume(invalid)) { error in
        XCTAssertEqual(error as? BEPStreamError, .malformedJSONLine)
      }
    }
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

  func testBuildMetadataRejectsUnsafeURLsAndUnboundedValuesWithoutFailingTheBuild() throws {
    let secret = "do-not-retain-metadata-secret"
    let lines = [
      #"{"started":{"uuid":"49603573-5756-46e6-bdb8-fed092d6629d","buildToolVersion":"9.2.0"}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"original"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"https://ignored.example/"}]}}]}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"https://user:"#
        + secret + #"@build.example/invocation/"}]}}]}}"#,
      #"{"buildMetadata":{"metadata":{"REMOTE_CACHE":"BuildBuddy\n"#
        + secret + #""}}}"#,
      #"{"finished":{"overallSuccess":true}}"#,
    ]
    var validator = try BEPStreamValidator()
    let events = try validator.consume(Data((lines.joined(separator: "\n") + "\n").utf8))

    XCTAssertEqual(
      events,
      [
        .buildMetadata(
          .invocation(
            buildToolVersion: "9.2.0",
            id: "49603573-5756-46e6-bdb8-fed092d6629d"
          )
        ),
        .finished(succeeded: true),
      ]
    )
    XCTAssertFalse(String(describing: events).contains(secret))
    XCTAssertTrue(try validator.finish().succeeded)
  }

  func testBuildMetadataAcceptsLocalHTTPAndRejectsAmbiguousResultBases() throws {
    let invocationID = "49603573-5756-46e6-bdb8-fed092d6629d"
    let lines = [
      #"{"started":{"uuid":""# + invocationID + #"","buildToolVersion":"9.2.0"}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"http://localhost:8080/invocation/"}]}}]}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"https://one.example/"},{"optionName":"bes_results_url","optionValue":"https://two.example/"}]}}]}}"#,
      #"{"finished":{"overallSuccess":true}}"#,
    ]
    var validator = try BEPStreamValidator()
    let events = try validator.consume(Data((lines.joined(separator: "\n") + "\n").utf8))

    XCTAssertTrue(
      events.contains(
        .buildMetadata(.resultsURL("http://localhost:8080/invocation/" + invocationID))
      )
    )
    XCTAssertFalse(
      events.contains {
        guard case .buildMetadata(.resultsURL(let url)) = $0 else { return false }
        return url.contains("one.example") || url.contains("two.example")
      }
    )
    XCTAssertTrue(try validator.finish().succeeded)
  }

  func testBuildMetadataCanLinkResultsWhenTheOptionalVersionIsUnsafe() throws {
    let invocationID = "49603573-5756-46e6-bdb8-fed092d6629d"
    let lines = [
      #"{"started":{"uuid":""# + invocationID + #"","buildToolVersion":"9.2.0\nunsafe"}}"#,
      #"{"id":{"structuredCommandLine":{"commandLineLabel":"canonical"}},"structuredCommandLine":{"sections":[{"sectionLabel":"command options","optionList":{"option":[{"optionName":"bes_results_url","optionValue":"https://build.example/invocation/"}]}}]}}"#,
      #"{"finished":{"overallSuccess":true}}"#,
    ]
    var validator = try BEPStreamValidator()
    let events = try validator.consume(Data((lines.joined(separator: "\n") + "\n").utf8))

    XCTAssertEqual(
      events,
      [
        .buildMetadata(.resultsURL("https://build.example/invocation/" + invocationID)),
        .finished(succeeded: true),
      ]
    )
    XCTAssertTrue(try validator.finish().succeeded)
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
      ProxyEventProjection.project(
        .buildMetadata(
          .invocation(buildToolVersion: "9.2.0", id: "49603573-5756-46e6-bdb8-fed092d6629d")
        )
      ),
      []
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

  func testParsesOptInRealBazelBuildMetadata() throws {
    guard
      let path = ProcessInfo.processInfo.environment["BAZEL_PROXY_REAL_METADATA_BEP_PATH"]
    else {
      throw XCTSkip("Set BAZEL_PROXY_REAL_METADATA_BEP_PATH to a BuildBuddy-backed Bazel BEP")
    }

    let validation = try BEPStreamValidator.validate(fileAt: URL(fileURLWithPath: path))
    XCTAssertTrue(
      validation.events.contains {
        guard case .buildMetadata(.invocation) = $0 else { return false }
        return true
      }
    )
    XCTAssertTrue(
      validation.events.contains {
        guard case .buildMetadata(.resultsURL(let url)) = $0 else { return false }
        return url.hasPrefix("https://") && url.contains("/invocation/")
      }
    )
    XCTAssertTrue(
      validation.events.contains {
        guard case .buildMetadata(.remoteCache("BuildBuddy")) = $0 else { return false }
        return true
      }
    )
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
