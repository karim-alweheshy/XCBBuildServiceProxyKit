import Foundation
import XCTest

@testable import BazelProxyCore

final class FakeAdapterIntegrationTests: XCTestCase {
  func testExecutorComposesOutputBEPReceiptAndMaterialization() async throws {
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
    let collector = ExecutionEventCollector()
    let executor = BazelOperationExecutor(
      invocationPreparer: AdapterInvocationFactory(
        operationRootURL: fixture.rootURL.appendingPathComponent("operations")
      )
    )

    let result = await executor.execute(
      plan: plan,
      processEnvironment: ["HOME": "/safe/home", "PATH": "/usr/bin:/bin"]
    ) { event in
      await collector.append(event)
    }

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertNil(result.failure)
    XCTAssertTrue(result.processCompletion?.succeeded == true)
    XCTAssertTrue(result.bep?.result.succeeded == true)
    XCTAssertEqual(result.invocationReceipt?.command, "build")
    XCTAssertEqual(
      result.productReceipt?.products.map { $0.destinationURL.standardizedFileURL },
      [destination.standardizedFileURL]
    )
    XCTAssertEqual(
      try String(contentsOf: destination.appendingPathComponent("artifact"), encoding: .utf8),
      "fake-product"
    )
    let events = await collector.snapshot()
    XCTAssertTrue(
      events.contains { event in
        guard case .processOutput(let output) = event else { return false }
        return output.channel == .standardOutput
      })
    XCTAssertTrue(events.contains(.bep(.finished(succeeded: true))))
  }

  func testExecutorRejectsMalformedBEPBeforeReceiptOrProducts() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript(
      """
      #!/bin/sh
      printf '{"finished":{"overallSuccess":tru' > "$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
      exit 0
      """,
      fixture: fixture
    )
    let plan = try fixture.plan(operationID: "executor-malformed-bep")
    let executor = BazelOperationExecutor(
      invocationPreparer: AdapterInvocationFactory(
        operationRootURL: fixture.rootURL.appendingPathComponent("operations")
      )
    )

    let result = await executor.execute(plan: plan, processEnvironment: [:])

    XCTAssertEqual(result.status, .failed)
    XCTAssertEqual(result.failure?.phase, .bepValidation)
    XCTAssertNil(result.invocationReceipt)
    XCTAssertNil(result.productReceipt)
  }

  func testExecutorCleanNeverPreparesOrSpawnsAdapter() async throws {
    let fixture = try ManifestFixture()
    let source = fixture.workspaceURL.appendingPathComponent(
      "bazel-out/products/App.app",
      isDirectory: true
    )
    let destination = fixture.rootURL.appendingPathComponent(
      "DerivedProducts/App.app",
      isDirectory: true
    )
    let buildPlan = try planWithProduct(
      fixture: fixture,
      source: source,
      destination: destination
    )
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("artifact"))
    let cleanIntent = BuildIntent(
      action: .clean,
      architecture: buildPlan.intent.architecture,
      configuration: buildPlan.intent.configuration,
      mode: buildPlan.intent.mode,
      platform: buildPlan.intent.platform,
      projectContainerURL: buildPlan.intent.projectContainerURL,
      requestedTargets: buildPlan.intent.requestedTargets,
      schemeAction: "build",
      workspaceURL: buildPlan.intent.workspaceURL
    )
    let cleanPlan = ResolvedBuildPlan(
      adapterRequest: AdapterRequest(labels: [], outputGroups: [], targetIDs: []),
      evaluatedEnvironment: buildPlan.evaluatedEnvironment,
      intent: cleanIntent,
      manifest: buildPlan.manifest,
      manifestURL: buildPlan.manifestURL,
      operationID: "clean-no-adapter",
      targets: buildPlan.targets
    )
    let executor = BazelOperationExecutor(
      invocationPreparer: RejectingInvocationPreparer(),
      processSupervisor: RejectingProcessSupervisor()
    )

    let result = await executor.execute(plan: cleanPlan, processEnvironment: [:])

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(result.cleanReceipt?.removedDestinations, [destination])
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertNil(result.operationDirectoryURL)
    XCTAssertNil(result.processCompletion)
  }

  func testExecutorTaskCancellationTerminatesOwnedProcess() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript(
      """
      #!/bin/sh
      trap '' TERM
      printf 'adapter-running\n'
      while :; do /bin/sleep 1; done
      """,
      fixture: fixture
    )
    let plan = try fixture.plan(operationID: "executor-cancel")
    let executor = BazelOperationExecutor(
      invocationPreparer: AdapterInvocationFactory(
        operationRootURL: fixture.rootURL.appendingPathComponent("operations")
      ),
      cancellationGrace: 0.05
    )
    let task = Task {
      await executor.execute(plan: plan, processEnvironment: [:])
    }

    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = await task.value

    XCTAssertEqual(result.status, .cancelled)
    XCTAssertTrue(result.processCompletion?.cancellationRequested == true)
    XCTAssertNil(result.bep)
    XCTAssertNil(result.productReceipt)
  }

  func testExecutorIndexValidatesAdapterButSkipsProductMaterialization() async throws {
    let fixture = try ManifestFixture()
    let base = try fixture.plan(
      evaluatedEnvironment: [
        "ACTION": "indexbuild",
        "BAZEL_CONFIG": "rules_xcodeproj",
        "SRCROOT": "/workspace",
      ],
      operationID: "executor-index"
    )
    let mapping = base.manifest.targets[0]
    let destination = fixture.rootURL.appendingPathComponent(
      "DerivedProducts/App.app",
      isDirectory: true
    )
    let indexIntent = BuildIntent(
      action: .indexBuild,
      architecture: base.intent.architecture,
      configuration: base.intent.configuration,
      mode: .standard,
      platform: base.intent.platform,
      projectContainerURL: base.intent.projectContainerURL,
      requestedTargets: base.intent.requestedTargets,
      schemeAction: "build",
      workspaceURL: base.intent.workspaceURL
    )
    let plan = ResolvedBuildPlan(
      adapterRequest: AdapterRequest(
        labels: [mapping.bazelLabel],
        outputGroups: mapping.indexOutputGroups,
        targetIDs: [mapping.targetID]
      ),
      evaluatedEnvironment: base.evaluatedEnvironment,
      intent: indexIntent,
      manifest: base.manifest,
      manifestURL: base.manifestURL,
      operationID: base.operationID,
      targets: [
        ResolvedTargetPlan(
          mapping: mapping,
          productPaths: ResolvedProductPaths(
            bazelOutputRootURL: fixture.workspaceURL.appendingPathComponent("bazel-out"),
            destinationProductURL: destination,
            fullProductName: mapping.product.basename,
            sourceProductURL: fixture.workspaceURL.appendingPathComponent(
              "bazel-out/products/App.app"
            ),
            targetBuildDirectoryURL: destination.deletingLastPathComponent()
          )
        )
      ]
    )
    try setAdapterScript(indexSuccessScript(), fixture: fixture)
    let executor = BazelOperationExecutor(
      invocationPreparer: AdapterInvocationFactory(
        operationRootURL: fixture.rootURL.appendingPathComponent("operations")
      )
    )

    let result = await executor.execute(plan: plan, processEnvironment: [:])

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertTrue(result.bep?.result.succeeded == true)
    XCTAssertEqual(result.invocationReceipt?.modes["config"], "rules_xcodeproj_indexbuild")
    XCTAssertNil(result.productReceipt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

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

  private func indexSuccessScript() -> String {
    """
    #!/bin/sh
    set -eu
    printf '%s\n' \
      '{"buildMetrics":{"actionSummary":{"actionsExecuted":"1"}}}' \
      '{"finished":{"overallSuccess":true}}' \
      > "$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
    /bin/cat > "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT" <<EOF
    {"bazelrcs":[],"command":"build","commandOptions":["--config=rules_xcodeproj_indexbuild"],"environmentKeys":[],"labels":["//app:App"],"materialization":{"contract":"manifest-v2"},"modes":{"action":"indexbuild","config":"rules_xcodeproj_indexbuild","coverage":"NO","previews":"NO"},"outputGroups":["bc app-app","bi app-app","target_ids_list"],"provenance":{"bepPath":"$SWIFTBUILD_BAZEL_PROXY_BEP_PATH"},"schemaVersion":1,"startupOptions":[],"targetIDs":["app-app"],"targets":["//app:AppProject"],"workingDirectory":"$PWD"}
    EOF
    /bin/chmod 600 "$SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"
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

private actor ExecutionEventCollector {
  private var events = [BazelOperationExecutionEvent]()

  func append(_ event: BazelOperationExecutionEvent) {
    events.append(event)
  }

  func snapshot() -> [BazelOperationExecutionEvent] {
    events
  }
}

private struct RejectingInvocationPreparer: AdapterInvocationPreparing {
  func make(
    for plan: ResolvedBuildPlan,
    processEnvironment: [String: String]
  ) throws -> AdapterInvocation {
    throw ExecutorTestFailure.unexpectedInvocation
  }
}

private struct RejectingProcessSupervisor: ProcessSupervising {
  func spawn(_ invocation: AdapterInvocation) throws -> any OwnedProcess {
    throw ExecutorTestFailure.unexpectedInvocation
  }
}

private enum ExecutorTestFailure: Error {
  case unexpectedInvocation
}
