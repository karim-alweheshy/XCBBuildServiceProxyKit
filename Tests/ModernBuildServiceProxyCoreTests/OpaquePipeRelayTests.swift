import Darwin
import Foundation
import XCTest

@testable import ModernBuildServiceProxyCore

final class OpaquePipeRelayTests: XCTestCase {
  func testRelaysOpaqueBytesExactlyInBothDirections() throws {
    let script = try TemporaryExecutable(contents: "#!/bin/sh\nexec /bin/cat\n")
    defer { script.remove() }

    let clientInput = Pipe()
    let clientOutput = Pipe()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: clientOutput.fileHandleForWriting,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.2
    )
    let relayFinished = expectation(description: "relay finished")
    var result: Result<OpaquePipeRelay.Summary, Error>?
    DispatchQueue.global().async {
      result = Result { try relay.run() }
      relayFinished.fulfill()
    }

    let input = Data(
      makeTestFrame(channel: 99, payload: [0xD9, 0x01, 0x58, 0xCC, 0x2A])
        + makeTestFrame(channel: 0, payload: Array("EXIT".utf8))
    )
    try clientInput.fileHandleForWriting.write(contentsOf: input)
    try clientInput.fileHandleForWriting.close()
    wait(for: [relayFinished], timeout: 5)
    try clientOutput.fileHandleForWriting.close()
    let output = clientOutput.fileHandleForReading.readDataToEndOfFile()

    let summary = try XCTUnwrap(result).get()
    XCTAssertEqual(output, input)
    XCTAssertEqual(summary.clientToServiceBytes, UInt64(input.count))
    XCTAssertEqual(summary.serviceToClientBytes, UInt64(output.count))
    XCTAssertEqual(summary.terminationStatus, 0)
  }

  func testStopEscalatesForTermIgnoringProcessGroup() throws {
    let script = try TemporaryExecutable(
      contents: "#!/bin/sh\ntrap '' TERM\n/bin/sleep 30 &\nwait\n"
    )
    defer { script.remove() }

    let clientInput = Pipe()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: FileHandle.nullDevice,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.2
    )
    let relayFinished = expectation(description: "relay stopped")
    var result: Result<OpaquePipeRelay.Summary, Error>?
    DispatchQueue.global().async {
      result = Result { try relay.run() }
      relayFinished.fulfill()
    }

    Thread.sleep(forTimeInterval: 0.2)
    let started = Date()
    relay.requestStop()
    wait(for: [relayFinished], timeout: 3)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    let summary = try XCTUnwrap(result).get()
    XCTAssertNotEqual(summary.terminationStatus, 0)
    try? clientInput.fileHandleForWriting.close()
  }

  func testDestinationWriteFailureIsNotReportedAsCleanEOF() throws {
    let script = try TemporaryExecutable(contents: "#!/bin/sh\nexec /bin/cat\n")
    defer { script.remove() }

    let clientInput = Pipe()
    try clientInput.fileHandleForWriting.write(
      contentsOf: Data(makeTestFrame(channel: 1, payload: [0xA1, 0x58]))
    )
    try clientInput.fileHandleForWriting.close()
    let readOnlyOutput = try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/null"))
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: readOnlyOutput,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.2
    )

    XCTAssertThrowsError(try relay.run()) { error in
      guard case OpaquePipeRelayError.relayFailed(let direction, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(direction, "service-to-client")
    }
  }

  func testAsynchronousCrossDirectionSinkFailureStopsRelayAndRemainsFirstError() throws {
    let script = try TemporaryExecutable(
      contents: "#!/bin/sh\ntrap '' TERM\n/bin/sleep 30 &\nwait\n"
    )
    defer { script.remove() }

    let clientInput = Pipe()
    try clientInput.fileHandleForWriting.write(
      contentsOf: Data(makeTestFrame(channel: 1, payload: Array("CREATE_BUILD".utf8)))
    )
    try clientInput.fileHandleForWriting.close()
    let readOnlyOutput = try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/null"))
    let interceptor = AsynchronousXcodeInjectionInterceptor()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: readOnlyOutput,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.1,
      frameInterceptor: interceptor
    )

    let started = Date()
    XCTAssertThrowsError(try relay.run()) { error in
      guard case OpaquePipeRelayError.relayFailed(let direction, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(direction, "service-to-client")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertEqual(interceptor.finished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(interceptor.errorDescriptions.count, 2)
    XCTAssertEqual(
      interceptor.errorDescriptions.first,
      interceptor.errorDescriptions.last,
      "A later asynchronous send replaced the first latched sink failure"
    )
  }

  func testRelayQuiescesInterceptorAndClosesRetainedOutputsBeforeReturning() throws {
    let script = try TemporaryExecutable(contents: "#!/bin/sh\n/bin/cat\n")
    defer { script.remove() }
    let clientInput = Pipe()
    try clientInput.fileHandleForWriting.write(
      contentsOf: Data(makeTestFrame(channel: 1, payload: Array("CREATE_BUILD".utf8)))
    )
    try clientInput.fileHandleForWriting.close()
    let clientOutput = Pipe()
    let interceptor = RetainedOutputsInterceptor()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: clientOutput.fileHandleForWriting,
      errorOutput: FileHandle.nullDevice,
      frameInterceptor: interceptor
    )

    _ = try relay.run()
    XCTAssertTrue(interceptor.willCloseCalled)
    XCTAssertTrue(interceptor.waitCalled)
    let outputs = try XCTUnwrap(interceptor.outputs)
    XCTAssertThrowsError(
      try outputs.sendToNative(BuildServiceRawFrame(channel: 2, payload: [2]))
    ) {
      XCTAssertEqual($0 as? BuildServiceFrameOutputsError, .relayClosed)
    }
    XCTAssertThrowsError(
      try outputs.sendToXcode(BuildServiceRawFrame(channel: 3, payload: [3]))
    ) {
      XCTAssertEqual($0 as? BuildServiceFrameOutputsError, .relayClosed)
    }
  }

  func testProxySignalHandlersAreInstalledOnlyAfterChildLaunch() throws {
    let script = try TemporaryExecutable(
      contents: "#!/bin/sh\n/bin/sleep 0.2\nkill -TERM $$\nprintf 'survived'\n"
    )
    defer { script.remove() }

    signal(SIGTERM, SIG_DFL)
    defer { signal(SIGTERM, SIG_DFL) }
    let clientInput = Pipe()
    try clientInput.fileHandleForWriting.close()
    let clientOutput = Pipe()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: clientOutput.fileHandleForWriting,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.2
    )

    let summary = try relay.run {
      signal(SIGTERM, SIG_IGN)
    }
    signal(SIGTERM, SIG_DFL)
    try clientOutput.fileHandleForWriting.close()
    let output = clientOutput.fileHandleForReading.readDataToEndOfFile()

    XCTAssertNotEqual(summary.terminationStatus, 0)
    XCTAssertTrue(output.isEmpty)
  }

  func testStopInterruptsBlockedAsynchronousOutputWithinBoundedGrace() throws {
    let script = try TemporaryExecutable(contents: "#!/bin/sh\n/bin/sleep 30\n")
    defer { script.remove() }
    let clientInput = Pipe()
    let clientOutput = Pipe()
    let interceptor = BlockingXcodeInjectionInterceptor()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: clientOutput.fileHandleForWriting,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.2,
      frameInterceptor: interceptor
    )
    let relayFinished = DispatchSemaphore(value: 0)
    let result = ThreadSafeRelayResultBox()
    DispatchQueue.global(qos: .userInitiated).async {
      result.store(Result { try relay.run() })
      relayFinished.signal()
    }

    try clientInput.fileHandleForWriting.write(
      contentsOf: Data(makeTestFrame(channel: 1, payload: Array("CREATE_BUILD".utf8)))
    )
    XCTAssertEqual(interceptor.started.wait(timeout: .now() + 2), .success)
    let stopStarted = Date()
    relay.requestStop()
    XCTAssertEqual(interceptor.finished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(relayFinished.wait(timeout: .now() + 2), .success)
    XCTAssertLessThan(Date().timeIntervalSince(stopStarted), 1.5)
    XCTAssertNotNil(result.value)
    XCTAssertEqual(interceptor.error as? BuildServiceFrameOutputsError, .relayClosed)
    try? clientInput.fileHandleForWriting.close()
  }

  func testRelayRechecksInterceptorQuiescenceAfterClosingBlockedOutput() throws {
    let script = try TemporaryExecutable(contents: "#!/bin/sh\n/bin/cat >/dev/null\n")
    defer { script.remove() }
    let clientInput = Pipe()
    let clientOutput = Pipe()
    let interceptor = CloseUnblocksQuiescenceInterceptor()
    let relay = OpaquePipeRelay(
      executableURL: script.url,
      environment: [:],
      input: clientInput.fileHandleForReading,
      output: clientOutput.fileHandleForWriting,
      errorOutput: FileHandle.nullDevice,
      terminationGrace: 0.1,
      frameInterceptor: interceptor
    )

    try clientInput.fileHandleForWriting.write(
      contentsOf: Data(makeTestFrame(channel: 1, payload: [0xA5]))
    )
    try clientInput.fileHandleForWriting.close()

    _ = try relay.run()

    XCTAssertGreaterThanOrEqual(interceptor.waitCount, 2)
    XCTAssertEqual(interceptor.error as? BuildServiceFrameOutputsError, .relayClosed)
  }
}

private final class CloseUnblocksQuiescenceInterceptor: BuildServiceFrameInterceptor {
  private let finished = DispatchSemaphore(value: 0)
  private let started = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var retainedOutputs: BuildServiceFrameOutputs?
  private var sendError: Error?
  private var waits = 0

  var error: Error? {
    lock.withLock { sendError }
  }

  var waitCount: Int {
    lock.withLock { waits }
  }

  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    direction == .clientToService
  }

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    lock.withLock { retainedOutputs = outputs }
    return true
  }

  func buildServiceRelayWillClose() {
    guard let outputs = lock.withLock({ retainedOutputs }) else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      defer { self.finished.signal() }
      self.started.signal()
      do {
        try outputs.sendToXcode(
          BuildServiceRawFrame(
            channel: 1,
            payload: [UInt8](repeating: 0xA5, count: 2 * 1024 * 1024)
          )
        )
      } catch {
        self.lock.withLock { self.sendError = error }
      }
    }
  }

  func buildServiceRelayWaitForQuiescence(timeout: TimeInterval) -> Bool {
    let waitNumber = lock.withLock {
      waits += 1
      return waits
    }
    if waitNumber == 1,
      started.wait(timeout: .now() + timeout) != .success
    {
      return false
    }
    return finished.wait(timeout: .now() + timeout) == .success
  }
}

private final class BlockingXcodeInjectionInterceptor: BuildServiceFrameInterceptor {
  let finished = DispatchSemaphore(value: 0)
  let started = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var sendError: Error?

  var error: Error? {
    lock.withLock { sendError }
  }

  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    direction == .clientToService
  }

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    DispatchQueue.global(qos: .userInitiated).async {
      defer { self.finished.signal() }
      self.started.signal()
      do {
        try outputs.sendToXcode(
          BuildServiceRawFrame(
            channel: frame.channel,
            payload: [UInt8](repeating: 0xA5, count: 2 * 1024 * 1024)
          )
        )
      } catch {
        self.lock.withLock { self.sendError = error }
      }
    }
    return true
  }
}

private final class ThreadSafeRelayResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Result<OpaquePipeRelay.Summary, Error>?

  var value: Result<OpaquePipeRelay.Summary, Error>? {
    lock.withLock { storedValue }
  }

  func store(_ value: Result<OpaquePipeRelay.Summary, Error>) {
    lock.withLock { storedValue = value }
  }
}

private final class AsynchronousXcodeInjectionInterceptor: BuildServiceFrameInterceptor {
  let finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var errors: [String] = []

  var errorDescriptions: [String] {
    lock.withLock { errors }
  }

  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    direction == .clientToService
  }

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    DispatchQueue.global(qos: .userInitiated).async {
      defer { self.finished.signal() }
      for marker in [UInt8(1), UInt8(2)] {
        do {
          try outputs.sendToXcode(
            BuildServiceRawFrame(channel: frame.channel, payload: [marker])
          )
        } catch {
          self.lock.withLock { self.errors.append(error.localizedDescription) }
        }
      }
    }
    return true
  }
}

private final class RetainedOutputsInterceptor: BuildServiceFrameInterceptor {
  private(set) var outputs: BuildServiceFrameOutputs?
  private(set) var waitCalled = false
  private(set) var willCloseCalled = false

  func shouldIntercept(
    direction: BuildServiceFrameDirection,
    channel: UInt64,
    payloadLength: UInt32,
    messageName: String?
  ) -> Bool {
    direction == .clientToService
  }

  func intercept(
    direction: BuildServiceFrameDirection,
    frame: BuildServiceRawFrame,
    outputs: BuildServiceFrameOutputs
  ) throws -> Bool {
    self.outputs = outputs
    return true
  }

  func buildServiceRelayWillClose() {
    willCloseCalled = true
  }

  func buildServiceRelayWaitForQuiescence(timeout: TimeInterval) -> Bool {
    waitCalled = true
    return true
  }
}

private func makeTestFrame(channel: UInt64, payload: [UInt8]) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: channel >> UInt64($0 * 8)) }
    + (0..<4).map {
      UInt8(truncatingIfNeeded: UInt32(payload.count) >> UInt32($0 * 8))
    } + payload
}

private final class TemporaryExecutable {
  let rootURL: URL
  let url: URL

  init(contents: String) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    url = rootURL.appendingPathComponent("service")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
