import Foundation
import XCTest

@testable import BazelProxyCore

final class BazelActionDetailsTests: XCTestCase {
  func testExecutionLogClassifiesCacheSourcesAndSanitizesCommands() throws {
    let fixture = try TemporaryExecutionLog()
    defer { fixture.remove() }
    try fixture.write(
      #"{"commandArgs":["swiftc","--remote_header","Authorization=Bearer fake-secret","https://user:password@example.invalid/Input.swift"],"listedOutputs":["bazel-out/App.swiftmodule"],"mnemonic":"SwiftCompile","runner":"remote cache hit","cacheHit":true,"exitCode":0,"targetLabel":"@@//app:App"}"#
        + "\n"
        + #"{"commandArgs":["libtool","-o","bazel-out/libApp.a"],"listedOutputs":["bazel-out/libApp.a"],"mnemonic":"CppArchive","runner":"disk cache hit","cacheHit":true,"exitCode":0,"targetLabel":"//app:App"}"#
        + "\n"
        + #"{"commandArgs":["clang","-o","bazel-out/App"],"listedOutputs":["bazel-out/App"],"mnemonic":"ObjcLink","runner":"local sandbox","cacheHit":false,"status":"SUCCESS","exitCode":0,"targetLabel":"//app:App"}"#
        + "\n"
        + #"{"listedOutputs":["bazel-out/Other"],"runner":"other cache","cacheHit":true,"targetLabel":"//app:Other"}"#
        + "\n"
    )

    let validation = try BazelExecutionLogValidator.validate(fileAt: fixture.url)
    XCTAssertEqual(validation.records.count, 4)
    XCTAssertEqual(validation.records[0].cacheKind, .remote)
    XCTAssertEqual(validation.records[1].cacheKind, .disk)
    XCTAssertFalse(validation.records[2].cacheHit)
    XCTAssertEqual(validation.records[2].runner, "local sandbox")
    XCTAssertEqual(validation.records[3].cacheKind, .other)
    let command = try XCTUnwrap(validation.records[0].commandLineDisplayString)
    XCTAssertTrue(command.contains("<redacted>"))
    XCTAssertFalse(command.contains("fake-secret"))
    XCTAssertFalse(command.contains("user:password"))

    let key = BazelActionReconciliationKey(
      label: "//app:App",
      primaryOutput: "bazel-out/App.swiftmodule"
    )
    XCTAssertEqual(validation.record(for: key), validation.records[0])
  }

  func testExecutionLogRejectsMalformedOversizedSymlinkAndAmbiguousData() throws {
    let fixture = try TemporaryExecutionLog()
    defer { fixture.remove() }

    try fixture.write("{\"cacheHit\":")
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: fixture.url)) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .malformedJSONLine)
    }

    try fixture.write(String(repeating: "x", count: 65))
    XCTAssertThrowsError(
      try BazelExecutionLogValidator.validate(
        fileAt: fixture.url,
        limits: BazelExecutionLogLimits(maximumFileBytes: 64, maximumLineBytes: 32)
      )
    ) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .fileLimitExceeded(64))
    }

    try fixture.write(
      #"{"listedOutputs":["out"],"targetLabel":"//app:App","cacheHit":false}"# + "\n"
        + #"{"listedOutputs":["out"],"targetLabel":"@//app:App","cacheHit":true}"# + "\n"
    )
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: fixture.url)) { error in
      XCTAssertEqual(
        error as? BazelExecutionLogError,
        .ambiguousRecord(label: "//app:App", output: "out")
      )
    }

    let linked = fixture.root.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.url)
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: linked)) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .unsafeFile(linked.path))
    }
  }

  func testContradictoryCacheHitFailsClosedAndFailedBEPRemainsFailed() throws {
    let fixture = try TemporaryExecutionLog()
    defer { fixture.remove() }
    try fixture.write(
      #"{"listedOutputs":["out"],"targetLabel":"//app:App","cacheHit":true,"exitCode":1,"status":"FAILED"}"#
        + "\n"
    )
    XCTAssertThrowsError(try BazelExecutionLogValidator.validate(fileAt: fixture.url)) { error in
      XCTAssertEqual(error as? BazelExecutionLogError, .malformedJSONLine)
    }

    let presented = BazelPresentedAction(
      completed: BEPActionCompleted(
        configuration: "sim",
        identity: "//app:App|out|sim",
        label: "//app:App",
        mnemonic: "ObjcLink",
        primaryOutput: "out",
        succeeded: false
      ),
      executionRecord: BazelExecutionRecord(
        cacheHit: true,
        commandLineDisplayString: "clang",
        exitCode: 0,
        listedOutputs: ["out"],
        mnemonic: "ObjcLink",
        runner: "remote cache hit",
        status: "SUCCESS",
        targetLabel: "//app:App"
      )
    )
    XCTAssertEqual(presented.disposition, .completed(succeeded: false))
  }

  func testCommandLimitsOmitDisplayWithoutFailingAndEnvironmentShapedArgumentsAreRedacted() throws {
    XCTAssertEqual(
      BazelCommandDisplay.sanitize(
        ["tool", "too-long"],
        limits: BazelCommandDisplayLimits(
          maximumArgumentBytes: 4,
          maximumArgumentCount: 2,
          maximumDisplayBytes: 32
        )
      ),
      BazelCommandDisplay.omittedPlaceholder
    )

    let command = try XCTUnwrap(
      BazelCommandDisplay.sanitize([
        "bazel", "--action_env", "API_TOKEN=fake", "--remote_header=Cookie=fake-cookie",
        "--token:colon-secret", "https://example.invalid/path?x=1&token=query-secret&safe=2",
      ])
    )
    XCTAssertFalse(command.contains("fake"))
    XCTAssertTrue(command.contains("API_TOKEN=<redacted>"))
    XCTAssertTrue(command.contains("--remote_header=<redacted>"))
    XCTAssertTrue(command.contains("--token:<redacted>"))
    XCTAssertFalse(command.contains("colon-secret"))
    XCTAssertFalse(command.contains("query-secret"))
    XCTAssertTrue(command.contains("x=1&token=<redacted>&safe=2"))
  }

  func testNativeStyleTaskTitlesAndTruthfulAbsentDisposition() {
    let cases = [
      ("SwiftCompile", "bazel-out/App.swiftmodule", "Compile Swift module App"),
      ("CppArchive", "bazel-out/libApp.a", "Archive App"),
      ("ObjcLink", "bazel-out/App", "Link App"),
      ("BundleTreeApp", "bazel-out/App.app", "Assemble App.app"),
      ("Symlink", "bazel-out/App_lipobin", "Create symlink App_lipobin"),
      ("BazelWorkspaceStatusAction", "stable-status.txt", "Update Bazel workspace status"),
      ("FileWrite", "bazel-out/App-link.params", "Write App-link.params"),
      ("CompileRootInfoPlist", "bazel-out/Info.plist", "Process Info.plist"),
      ("ProcessEntitlementsFiles", "bazel-out/App.entitlements", "Process entitlements"),
      ("ProcessDEREntitlements", "bazel-out/App.der", "Process DER entitlements"),
      (
        "ProcessSimulatorEntitlementsFile", "bazel-out/App-sim.entitlements",
        "Process simulator entitlements"
      ),
      ("Action", "bazel-out/App.runner_entitlements", "Generate App.runner_entitlements"),
      ("CustomMnemonic", "bazel-out/output", "CustomMnemonic output"),
    ]
    for (mnemonic, output, expected) in cases {
      let action = BazelPresentedAction(
        upToDate: BazelConfiguredAction(
          configuration: "sim",
          label: "//app:App",
          mnemonic: mnemonic,
          primaryOutput: output
        )
      )
      XCTAssertEqual(action.taskTitle, expected)
      XCTAssertEqual(action.disposition, .upToDate)
    }
  }
}

private struct TemporaryExecutionLog {
  let root: URL
  let url: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    url = root.appendingPathComponent("execution-log.jsonl")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func write(_ contents: String) throws {
    try Data(contents.utf8).write(to: url, options: .atomic)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
