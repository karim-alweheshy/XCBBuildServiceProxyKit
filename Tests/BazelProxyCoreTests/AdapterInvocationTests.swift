import Darwin
import Foundation
import XCTest

@testable import BazelProxyCore

final class AdapterInvocationTests: XCTestCase {
  func testCreatesDeterministicRestrictedInvocation() throws {
    let fixture = try ManifestFixture()
    let root = fixture.rootURL.appendingPathComponent("operations", isDirectory: true)
    let factory = AdapterInvocationFactory(operationRootURL: root)
    let basePlan = try fixture.plan()
    let request = AdapterRequest(
      labels: ["//z:Z", "//a:A", "//z:Z"],
      outputGroups: ["bp z", "bp a", "bp a"],
      targetIDs: ["z", "a", "z"]
    )
    let plan = ResolvedBuildPlan(
      adapterRequest: request,
      evaluatedEnvironment: basePlan.evaluatedEnvironment,
      intent: basePlan.intent,
      manifest: basePlan.manifest,
      manifestURL: basePlan.manifestURL,
      operationID: "operation-one",
      targets: basePlan.targets
    )
    let invocation = try factory.make(
      for: plan,
      processEnvironment: [
        "AUTH_TOKEN": "discarded-value",
        "HOME": "/safe/home",
        "PATH": "/usr/bin:/bin",
        "UNDECLARED": "discarded",
      ]
    )

    XCTAssertEqual(invocation.executableURL, fixture.adapterURL.resolvingSymlinksInPath())
    XCTAssertEqual(invocation.arguments, [])
    XCTAssertEqual(invocation.workingDirectoryURL, fixture.workspaceURL)
    XCTAssertEqual(try contents("labels", invocation), "//a:A\n//z:Z\n")
    XCTAssertEqual(try contents("target_ids", invocation), "a\nz\n")
    XCTAssertEqual(try contents("output_groups", invocation), "bp a\nbp z\n")
    XCTAssertEqual(try permissions(invocation.operationDirectoryURL), 0o700)
    XCTAssertEqual(try permissions(invocation.requestDirectoryURL), 0o700)
    for file in ["labels", "target_ids", "output_groups"] {
      XCTAssertEqual(
        try permissions(invocation.requestDirectoryURL.appendingPathComponent(file)),
        0o600
      )
    }
    XCTAssertEqual(invocation.environment["HOME"], "/safe/home")
    XCTAssertEqual(invocation.environment["ACTION"], "build")
    XCTAssertNil(invocation.environment["AUTH_TOKEN"])
    XCTAssertNil(invocation.environment["UNDECLARED"])
    XCTAssertEqual(
      Set(invocation.environment.keys),
      [
        "ACTION", "BAZEL_CONFIG", "HOME", "PATH", "SRCROOT",
        AdapterInvocationFactory.actionStartsEnvironmentKey,
        AdapterInvocationFactory.bepEnvironmentKey,
        AdapterInvocationFactory.executionLogEnvironmentKey,
        AdapterInvocationFactory.profileEnvironmentKey,
        AdapterInvocationFactory.receiptEnvironmentKey,
        AdapterInvocationFactory.requestDirectoryEnvironmentKey,
      ]
    )
    XCTAssertNil(invocation.environment[AdapterInvocationFactory.actionGraphEnvironmentKey])
    XCTAssertEqual(
      invocation.environment[AdapterInvocationFactory.actionStartsEnvironmentKey],
      invocation.actionStartsURL.path
    )
    XCTAssertEqual(invocation.actionStartsURL.lastPathComponent, "action-starts.jsonl")
    XCTAssertEqual(
      invocation.environment[AdapterInvocationFactory.executionLogEnvironmentKey],
      invocation.executionLogURL.path
    )
    XCTAssertEqual(invocation.executionLogURL.lastPathComponent, "execution-log")
    XCTAssertEqual(
      invocation.environment[AdapterInvocationFactory.profileEnvironmentKey],
      invocation.profileURL.path
    )
    XCTAssertEqual(invocation.profileURL.lastPathComponent, "bazel-profile.json.gz")
    XCTAssertEqual(
      invocation.environment[AdapterInvocationFactory.requestDirectoryEnvironmentKey],
      invocation.requestDirectoryURL.path
    )
    XCTAssertNil(basePlan.targets[0].productPaths)

    let secondPlan = ResolvedBuildPlan(
      adapterRequest: request,
      evaluatedEnvironment: basePlan.evaluatedEnvironment,
      intent: basePlan.intent,
      manifest: basePlan.manifest,
      manifestURL: basePlan.manifestURL,
      operationID: "operation-two",
      targets: basePlan.targets
    )
    let second = try factory.make(for: secondPlan, processEnvironment: [:])
    XCTAssertEqual(try contents("labels", invocation), try contents("labels", second))
    XCTAssertEqual(try contents("target_ids", invocation), try contents("target_ids", second))
    XCTAssertEqual(
      try contents("output_groups", invocation),
      try contents("output_groups", second)
    )
  }

  func testRejectsNonExecutableAndSymlinkedAdapter() throws {
    let fixture = try ManifestFixture()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.adapterURL.path
    )
    let factory = AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    )
    XCTAssertThrowsError(try factory.make(for: fixture.plan(), processEnvironment: [:])) { error in
      guard case .adapterIsNotExecutable = error as? AdapterInvocationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    try FileManager.default.removeItem(at: fixture.adapterURL)
    let outsideURL = fixture.rootURL.appendingPathComponent("outside.sh")
    guard
      FileManager.default.createFile(
        atPath: outsideURL.path,
        contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755]
      )
    else {
      return XCTFail("Could not create outside adapter")
    }
    try FileManager.default.createSymbolicLink(
      at: fixture.adapterURL,
      withDestinationURL: outsideURL
    )
    XCTAssertThrowsError(try factory.make(for: fixture.plan(), processEnvironment: [:])) { error in
      guard case .unsafeAdapter = error as? AdapterInvocationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsSymlinkedOperationRoot() throws {
    let fixture = try ManifestFixture()
    let physicalRoot = fixture.rootURL.appendingPathComponent("physical-operations")
    try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: false)
    let symlinkRoot = fixture.rootURL.appendingPathComponent("linked-operations")
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: physicalRoot)
    let factory = AdapterInvocationFactory(operationRootURL: symlinkRoot)

    XCTAssertThrowsError(try factory.make(for: fixture.plan(), processEnvironment: [:])) { error in
      guard case .unsafeOperationRoot = error as? AdapterInvocationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsUndeclaredEnvironmentAndCredentialShapedValues() throws {
    let fixture = try ManifestFixture()
    let factory = AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    )
    XCTAssertThrowsError(
      try factory.make(
        for: fixture.plan(evaluatedEnvironment: ["UNDECLARED": "value"]),
        processEnvironment: [:]
      )
    ) { error in
      XCTAssertEqual(error as? AdapterInvocationError, .undeclaredEnvironmentKey("UNDECLARED"))
    }

    XCTAssertThrowsError(
      try factory.make(
        for: fixture.plan(evaluatedEnvironment: ["ACTION": "token=fake-test-value"]),
        processEnvironment: [:]
      )
    ) { error in
      XCTAssertEqual(error as? AdapterInvocationError, .unsafeEnvironmentValue("ACTION"))
    }

    XCTAssertThrowsError(
      try factory.make(
        for: fixture.plan(),
        processEnvironment: ["HTTP_PROXY": "https://test-user:test-pass@example.invalid"]
      )
    ) { error in
      XCTAssertEqual(error as? AdapterInvocationError, .unsafeEnvironmentValue("HTTP_PROXY"))
    }
  }

  func testRejectsUnsafeRequestValueAndOperationID() throws {
    let fixture = try ManifestFixture()
    let basePlan = try fixture.plan()
    let root = fixture.rootURL.appendingPathComponent("operations")
    let factory = AdapterInvocationFactory(operationRootURL: root)
    let unsafeRequest = ResolvedBuildPlan(
      adapterRequest: AdapterRequest(
        labels: ["//app:App\n--config=unexpected"],
        outputGroups: ["bp app-app"],
        targetIDs: ["app-app"]
      ),
      evaluatedEnvironment: basePlan.evaluatedEnvironment,
      intent: basePlan.intent,
      manifest: basePlan.manifest,
      manifestURL: basePlan.manifestURL,
      operationID: "safe-operation",
      targets: basePlan.targets
    )
    XCTAssertThrowsError(try factory.make(for: unsafeRequest, processEnvironment: [:])) { error in
      guard case .unsafeRequestValue = error as? AdapterInvocationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    XCTAssertThrowsError(
      try factory.make(for: fixture.plan(operationID: "../escape"), processEnvironment: [:])
    ) { error in
      XCTAssertEqual(error as? AdapterInvocationError, .invalidOperationID("../escape"))
    }
  }

  private func contents(_ file: String, _ invocation: AdapterInvocation) throws -> String {
    try String(
      contentsOf: invocation.requestDirectoryURL.appendingPathComponent(file),
      encoding: .utf8
    )
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
