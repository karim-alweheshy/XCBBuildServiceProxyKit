import Darwin
import Foundation
import XCTest

@testable import BazelProxyCore

final class OwnedProcessSupervisorTests: XCTestCase {
  func testReportsSuccessfulAndFailedAdapterExitExactly() async throws {
    let successFixture = try ManifestFixture()
    try setAdapterScript(
      "#!/bin/sh\nprintf 'hello-out'\nprintf 'WARNING: hello-error\\n' >&2\nexit 0\n",
      fixture: successFixture)
    let successInvocation = try AdapterInvocationFactory(
      operationRootURL: successFixture.rootURL.appendingPathComponent("operations")
    ).make(for: successFixture.plan(), processEnvironment: [:])
    let successProcess = try OwnedProcessSupervisor().spawn(successInvocation)
    async let successEvents = collect(successProcess.events)
    let successCompletion = await successProcess.wait()
    let capturedSuccessEvents = await successEvents

    XCTAssertTrue(successCompletion.succeeded)
    XCTAssertEqual(successCompletion.termination, .exited(status: 0))
    XCTAssertEqual(successCompletion.outputDisposition, .complete)
    XCTAssertEqual(output(capturedSuccessEvents, channel: .standardOutput), "hello-out")
    XCTAssertEqual(
      output(capturedSuccessEvents, channel: .standardError),
      "WARNING: hello-error\n"
    )
    XCTAssertEqual(
      capturedSuccessEvents.map(\.sequence),
      Array(1...UInt64(capturedSuccessEvents.count))
    )

    let failureFixture = try ManifestFixture()
    try setAdapterScript("#!/bin/sh\nprintf 'failure' >&2\nexit 7\n", fixture: failureFixture)
    let failureInvocation = try AdapterInvocationFactory(
      operationRootURL: failureFixture.rootURL.appendingPathComponent("operations")
    ).make(for: failureFixture.plan(), processEnvironment: [:])
    let failureProcess = try OwnedProcessSupervisor().spawn(failureInvocation)
    async let failureEvents = collect(failureProcess.events)
    let failureCompletion = await failureProcess.wait()
    _ = await failureEvents

    XCTAssertFalse(failureCompletion.succeeded)
    XCTAssertEqual(failureCompletion.termination, .exited(status: 7))
    XCTAssertFalse(failureCompletion.cancellationRequested)
  }

  func testCancellationEscalatesOwnedGroupAndLeavesUnrelatedProcessAlive() async throws {
    let fixture = try ManifestFixture()
    let childPIDURL = fixture.workspaceURL.appendingPathComponent("child.pid")
    try setAdapterScript(
      """
      #!/bin/sh
      trap '' TERM
      /bin/sh -c 'trap "" TERM; /bin/sleep 30' &
      child=$!
      printf '%s\n' "$child" > '\(childPIDURL.path)'
      wait
      """,
      fixture: fixture
    )
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: fixture.plan(), processEnvironment: [:])
    let process = try OwnedProcessSupervisor().spawn(invocation)
    async let events = collect(process.events)
    try await waitForFile(childPIDURL)

    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["5"]
    try unrelated.run()
    defer {
      if unrelated.isRunning { unrelated.terminate() }
      unrelated.waitUntilExit()
    }

    let receipt = await process.cancel(gracePeriod: 0.1)
    _ = await events

    XCTAssertTrue(receipt.completion.cancellationRequested)
    XCTAssertEqual(receipt.term, .delivered)
    XCTAssertEqual(receipt.kill, .delivered)
    XCTAssertEqual(receipt.completion.termination, .signalled(signal: SIGKILL))
    XCTAssertTrue(unrelated.isRunning)
    let groupSurvived = try await processGroupExists(receipt.completion.processGroupID)
    XCTAssertFalse(groupSurvived)
  }

  func testOutputLimitTerminatesAdapterWithoutUnboundedBuffering() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript("#!/bin/sh\nexec /usr/bin/yes x\n", fixture: fixture)
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: fixture.plan(), processEnvironment: [:])
    let supervisor = OwnedProcessSupervisor(
      limits: ProcessOutputLimits(
        maximumBufferedEvents: 8,
        maximumBytesPerChannel: 128,
        maximumChunkBytes: 32,
        outputDrainGrace: 1,
        violationKillGrace: 0.05
      )
    )
    let process = try supervisor.spawn(invocation)
    async let events = collect(process.events)
    let completion = await process.wait()
    let capturedEvents = await events

    XCTAssertEqual(completion.outputDisposition, .byteLimitExceeded(.standardOutput))
    XCTAssertLessThanOrEqual(
      capturedEvents.reduce(0) { $0 + $1.bytes.count },
      128
    )
    XCTAssertFalse(completion.succeeded)
  }

  func testOutputDrainTimeoutKillsOwnedDescendantAndReturnsBoundedOutcome() async throws {
    let fixture = try ManifestFixture()
    try setAdapterScript(
      "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; /bin/sleep 30' &\nexit 0\n",
      fixture: fixture
    )
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: fixture.plan(), processEnvironment: [:])
    let supervisor = OwnedProcessSupervisor(
      limits: ProcessOutputLimits(outputDrainGrace: 0.05, violationKillGrace: 0.05)
    )

    let process = try supervisor.spawn(invocation)
    async let events = collect(process.events)
    let completion = await process.wait()
    _ = await events

    XCTAssertEqual(completion.termination, .exited(status: 0))
    XCTAssertEqual(completion.outputDisposition, .drainTimedOut)
    XCTAssertFalse(completion.succeeded)
    let groupSurvived = try await processGroupExists(completion.processGroupID)
    XCTAssertFalse(groupSurvived)
  }

  func testRejectsNonemptyAdapterArguments() throws {
    let fixture = try ManifestFixture()
    let invocation = try AdapterInvocationFactory(
      operationRootURL: fixture.rootURL.appendingPathComponent("operations")
    ).make(for: fixture.plan(), processEnvironment: [:])
    let modified = AdapterInvocation(
      actionGraphURL: invocation.actionGraphURL,
      arguments: ["--forbidden"],
      bepURL: invocation.bepURL,
      environment: invocation.environment,
      executionLogURL: invocation.executionLogURL,
      executableURL: invocation.executableURL,
      operationDirectoryURL: invocation.operationDirectoryURL,
      receiptURL: invocation.receiptURL,
      requestDirectoryURL: invocation.requestDirectoryURL,
      workingDirectoryURL: invocation.workingDirectoryURL
    )

    XCTAssertThrowsError(try OwnedProcessSupervisor().spawn(modified)) { error in
      XCTAssertEqual(error as? ProcessLaunchError, .adapterArgumentsAreNotEmpty)
    }
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

  private func waitForFile(_ url: URL) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: url.path) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(url.lastPathComponent)")
  }

  private func processGroupExists(_ groupID: pid_t) async throws -> Bool {
    for _ in 0..<200 {
      if kill(-groupID, 0) != 0, errno == ESRCH {
        return false
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
  }
}
