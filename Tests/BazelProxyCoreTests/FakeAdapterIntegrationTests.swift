import Foundation
import XCTest

@testable import BazelProxyCore

final class FakeAdapterIntegrationTests: XCTestCase {
  func testFakeAdapterSuccessProducesValidatedBEPReceiptAndProduct() async throws {
    let fixture = try ManifestFixture()
    let source = fixture.workspaceURL.appendingPathComponent(
      "bazel-out/products/App.app",
      isDirectory: true
    )
    let destination = fixture.rootURL.appendingPathComponent(
      "DerivedProducts/App.app",
      isDirectory: true
    )
    let plan = try planWithProduct(fixture: fixture, source: source, destination: destination)
    try setAdapterScript(successScript(), fixture: fixture)
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: ["HOME": "/safe/home", "PATH": "/usr/bin:/bin"])

    let process = try OwnedProcessSupervisor().spawn(invocation)
    async let outputEvents = collect(process.events)
    let completion = await process.wait()
    let capturedEvents = await outputEvents

    XCTAssertTrue(completion.succeeded)
    XCTAssertEqual(completion.termination, .exited(status: 0))
    XCTAssertEqual(output(capturedEvents, channel: .standardOutput), "fake adapter complete\n")
    let diagnostic = DiagnosticParser.parse(
      line: output(capturedEvents, channel: .standardError)
    )
    XCTAssertEqual(diagnostic?.severity, .warning)

    let bep = try BEPStreamValidator.validate(fileAt: invocation.bepURL)
    XCTAssertTrue(bep.result.succeeded)
    XCTAssertEqual(bep.result.completedActionIDs.count, 1)
    XCTAssertTrue(bep.events.contains(.finished(succeeded: true)))

    let receipt = try InvocationReceiptValidator.loadAndValidate(
      for: plan,
      invocation: invocation
    )
    XCTAssertEqual(receipt.command, "build")
    XCTAssertEqual(receipt.materialization, ["contract": "manifest-v2"])

    let productReceipt = try ProductMaterializer().materialize(plan: plan)
    XCTAssertEqual(
      productReceipt.products.map { $0.destinationURL.standardizedFileURL },
      [destination.standardizedFileURL]
    )
    XCTAssertEqual(
      try String(contentsOf: destination.appendingPathComponent("artifact"), encoding: .utf8),
      "fake-product"
    )
  }

  func testFakeAdapterMalformedBEPFailsValidationAfterCleanExit() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript(
      """
      #!/bin/sh
      printf '{"finished":{"overallSuccess":tru' > "$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
      exit 0
      """,
      fixture: fixture
    )
    let plan = try fixture.plan(operationID: "malformed-bep")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    let process = try OwnedProcessSupervisor().spawn(invocation)
    async let events = collect(process.events)
    let completion = await process.wait()
    _ = await events
    XCTAssertTrue(completion.succeeded)

    var validator = try BEPStreamValidator()
    _ = try validator.consume(Data(contentsOf: invocation.bepURL))
    XCTAssertThrowsError(try validator.finish()) { error in
      XCTAssertEqual(error as? BEPStreamError, .malformedJSONLine)
    }
  }

  func testFakeAdapterMalformedReceiptFailsStrictValidation() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript(
      """
      #!/bin/sh
      printf '%s\n' '{"finished":{"overallSuccess":true}}' > "$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
      printf '%s\n' '{"schemaVersion":1}' > "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"
      /bin/chmod 600 "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"
      exit 0
      """,
      fixture: fixture
    )
    let plan = try fixture.plan(operationID: "malformed-receipt")
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: plan, processEnvironment: [:])
    let process = try OwnedProcessSupervisor().spawn(invocation)
    async let events = collect(process.events)
    let completion = await process.wait()
    _ = await events
    XCTAssertTrue(completion.succeeded)

    XCTAssertThrowsError(
      try InvocationReceiptValidator.loadAndValidate(for: plan, invocation: invocation)
    ) { error in
      guard case .invalidShape = error as? InvocationReceiptError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func successScript() -> String {
    """
    #!/bin/sh
    set -eu
    /bin/mkdir -p "$PWD/bazel-out/products/App.app"
    printf 'fake-product' > "$PWD/bazel-out/products/App.app/artifact"
    printf '%s\n' \
      '{"id":{"actionCompleted":{"configuration":"sim-arm64","label":"//app:App","primaryOutput":"bazel-out/products/App.app"}},"action":{"success":true}}' \
      '{"id":{"targetCompleted":{"label":"//app:App"}},"completed":{"success":true}}' \
      '{"buildMetrics":{"actionSummary":{"actionsExecuted":"1"}}}' \
      '{"finished":{"overallSuccess":true}}' \
      > "$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
    /bin/cat > "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT" <<EOF
    {"bazelrcs":[],"command":"build","commandOptions":["--config=_rules_xcodeproj_build"],"environmentKeys":["HOME","PATH"],"labels":["//app:App"],"materialization":{"contract":"manifest-v2"},"modes":{"action":"build","config":"_rules_xcodeproj_build","coverage":"NO","previews":"NO"},"outputGroups":["bp app-app","index_import","target_ids_list"],"provenance":{"bepPath":"$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"},"schemaVersion":1,"startupOptions":[],"targetIDs":["app-app"],"targets":["//app:AppProject"],"workingDirectory":"$PWD"}
    EOF
    /bin/chmod 600 "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"
    printf 'WARNING: fake adapter warning\n' >&2
    printf 'fake adapter complete\n'
    """
  }

  private func planWithProduct(
    fixture: ManifestFixture,
    source: URL,
    destination: URL
  ) throws -> ResolvedBuildPlan {
    let base = try fixture.plan(operationID: "fake-success")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return ResolvedBuildPlan(
      adapterRequest: base.adapterRequest,
      evaluatedEnvironment: base.evaluatedEnvironment,
      intent: base.intent,
      manifest: base.manifest,
      manifestURL: base.manifestURL,
      operationID: base.operationID,
      targets: [
        ResolvedTargetPlan(
          mapping: base.manifest.targets[0],
          productPaths: ResolvedProductPaths(
            bazelOutputRootURL: fixture.workspaceURL.appendingPathComponent("bazel-out"),
            destinationProductURL: destination,
            fullProductName: base.manifest.targets[0].product.basename,
            sourceProductURL: source,
            targetBuildDirectoryURL: destination.deletingLastPathComponent()
          )
        )
      ]
    )
  }

  private func setAdapterScript(_ script: String, fixture: ManifestFixture) throws {
    try Data(script.utf8).write(to: fixture.adapterURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.adapterURL.path
    )
  }

  private func collect(_ stream: AsyncStream<ProcessOutputEvent>) async -> [ProcessOutputEvent] {
    var result = [ProcessOutputEvent]()
    for await event in stream {
      result.append(event)
    }
    return result
  }

  private func output(
    _ events: [ProcessOutputEvent],
    channel: ProcessOutputChannel
  ) -> String {
    String(decoding: events.filter { $0.channel == channel }.flatMap { $0.bytes }, as: UTF8.self)
  }
}
