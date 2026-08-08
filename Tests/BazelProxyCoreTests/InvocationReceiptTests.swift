import Foundation
import XCTest

@testable import BazelProxyCore

final class InvocationReceiptTests: XCTestCase {
  func testValidatesSchemaV1ReceiptAgainstPlanAndRequestFiles() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-valid")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    try writeReceipt(validReceipt(plan: plan, invocation: invocation), to: invocation.receiptURL)

    let receipt = try InvocationReceiptValidator.loadAndValidate(
      for: plan,
      invocation: invocation
    )

    XCTAssertEqual(receipt.schemaVersion, 1)
    XCTAssertEqual(receipt.labels, ["//app:App"])
    XCTAssertEqual(receipt.targetIDs, ["app-app"])
    XCTAssertTrue(Set(plan.adapterRequest.outputGroups).isSubset(of: receipt.outputGroups))
  }

  func testRejectsReceiptNotBoundToRequestOrBEPOutputs() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-binding")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    var object = validReceipt(plan: plan, invocation: invocation)
    object["outputGroups"] = ["index_import", "target_ids_list"]
    try writeReceipt(object, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("output groups"))
    }

    var wrongBEP = validReceipt(plan: plan, invocation: invocation)
    wrongBEP["provenance"] = ["bepPath": fixture.rootURL.appendingPathComponent("other").path]
    try writeReceipt(wrongBEP, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("BEP output"))
    }

    var wrongModes = validReceipt(plan: plan, invocation: invocation)
    wrongModes["modes"] = [
      "action": "build",
      "config": "rules_xcodeproj",
      "coverage": "NO",
      "previews": "YES",
    ]
    try writeReceipt(wrongModes, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("build modes"))
    }
  }

  func testRejectsTamperedRequestFileAndUnknownReceiptField() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-tamper")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    try writeReceipt(validReceipt(plan: plan, invocation: invocation), to: invocation.receiptURL)
    let labelsURL = invocation.requestDirectoryURL.appendingPathComponent("labels")
    try Data("//app:Other\n".utf8).write(to: labelsURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: labelsURL.path)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("request files"))
    }

    let secondFixture = try ManifestFixture()
    let secondPlan = try secondFixture.plan(operationID: "receipt-unknown")
    let secondInvocation = try AdapterInvocationFactory(
      operationRootURL: secondFixture.rootURL.appendingPathComponent("operations")
    ).make(for: secondPlan, processEnvironment: [:])
    var unknown = validReceipt(plan: secondPlan, invocation: secondInvocation)
    unknown["environmentValues"] = ["PATH": "/must/not/appear"]
    try writeReceipt(unknown, to: secondInvocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(
        for: secondPlan,
        invocation: secondInvocation
      )
    ) { error in
      guard case .invalidShape = error as? InvocationReceiptError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsCredentialShapedOptionsAndEnvironmentNames() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-secret-option")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    var option = validReceipt(plan: plan, invocation: invocation)
    option["commandOptions"] = ["--remote_header=Authorization=Bearer-fake-value"]
    try writeReceipt(option, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(
        error as? InvocationReceiptError,
        .credentialShapedContent("commandOptions")
      )
    }

    var environment = validReceipt(plan: plan, invocation: invocation)
    environment["environmentKeys"] = ["PRIVATE_AUTH_TOKEN"]
    try writeReceipt(environment, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(
        error as? InvocationReceiptError,
        .credentialShapedContent("environmentKeys")
      )
    }
  }

  func testRejectsSafeButUndeclaredEnvironmentKeyAndAllowsGeneratedKey() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-environment-contract")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])

    var generated = validReceipt(plan: plan, invocation: invocation)
    generated["environmentKeys"] = ["BAZEL_REAL", "HOME", "LANG", "PATH"]
    try writeReceipt(generated, to: invocation.receiptURL)
    XCTAssertNoThrow(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    )

    var undeclared = validReceipt(plan: plan, invocation: invocation)
    undeclared["environmentKeys"] = ["CUSTOM_BAZEL_ENV"]
    try writeReceipt(undeclared, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("environment keys"))
    }

    var proxyControl = validReceipt(plan: plan, invocation: invocation)
    proxyControl["environmentKeys"] = [AdapterInvocationFactory.bepEnvironmentKey]
    try writeReceipt(proxyControl, to: invocation.receiptURL)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .bindingMismatch("environment keys"))
    }
  }

  func testRejectsLinkedOrWorldReadableReceipt() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-file")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    try writeReceipt(validReceipt(plan: plan, invocation: invocation), to: invocation.receiptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: invocation.receiptURL.path
    )
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .unsafeFile(invocation.receiptURL.path))
    }

    let outside = fixture.rootURL.appendingPathComponent("outside-receipt.json")
    try writeReceipt(validReceipt(plan: plan, invocation: invocation), to: outside)
    try FileManager.default.removeItem(at: invocation.receiptURL)
    try FileManager.default.createSymbolicLink(
      at: invocation.receiptURL, withDestinationURL: outside)
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .unsafeFile(invocation.receiptURL.path))
    }
  }

  func testRejectsTruncatedAndOversizedReceipt() throws {
    let fixture = try ManifestFixture()
    let plan = try fixture.plan(operationID: "receipt-bounds")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])

    try Data("{".utf8).write(to: invocation.receiptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: invocation.receiptURL.path
    )
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      guard case .invalidJSON = error as? InvocationReceiptError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    try Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1).write(to: invocation.receiptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: invocation.receiptURL.path
    )
    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      XCTAssertEqual(error as? InvocationReceiptError, .unsafeFile(invocation.receiptURL.path))
    }
  }

  private func validReceipt(
    plan: ResolvedBuildPlan,
    invocation: AdapterInvocation
  ) -> [String: Any] {
    [
      "bazelrcs": [],
      "command": "build",
      "commandOptions": [],
      "environmentKeys": ["HOME", "PATH"],
      "labels": Array(Set(plan.adapterRequest.labels)).sorted(),
      "materialization": ["contract": "manifest-v2"],
      "modes": [
        "action": "build",
        "config": "rules_xcodeproj",
        "coverage": "NO",
        "previews": "NO",
      ],
      "outputGroups": Array(
        Set(plan.adapterRequest.outputGroups + ["index_import", "target_ids_list"])
      ).sorted(),
      "provenance": ["bepPath": invocation.bepURL.path],
      "schemaVersion": 1,
      "startupOptions": [],
      "targetIDs": Array(Set(plan.adapterRequest.targetIDs)).sorted(),
      "targets": [plan.manifest.invocation.generatorLabel],
      "workingDirectory": invocation.workingDirectoryURL.path,
    ]
  }

  private func writeReceipt(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
