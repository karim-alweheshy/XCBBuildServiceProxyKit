import Darwin
import Foundation
import XCTest

@testable import ModernBuildServiceProxyCore

final class OpaquePipeRelayTests: XCTestCase {
  func testRelaysOpaqueBytesExactlyInBothDirections() throws {
    let script = try TemporaryExecutable(
      contents: "#!/bin/sh\nwhile IFS= read -r line; do printf 'service:%s\\n' \"$line\"; done\n"
    )
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

    let input = Data("one\ntwo\n".utf8)
    try clientInput.fileHandleForWriting.write(contentsOf: input)
    try clientInput.fileHandleForWriting.close()
    wait(for: [relayFinished], timeout: 5)
    try clientOutput.fileHandleForWriting.close()
    let output = clientOutput.fileHandleForReading.readDataToEndOfFile()

    let summary = try XCTUnwrap(result).get()
    XCTAssertEqual(output, Data("service:one\nservice:two\n".utf8))
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
    let script = try TemporaryExecutable(contents: "#!/bin/sh\nprintf 'response'\n/bin/sleep 30\n")
    defer { script.remove() }

    let clientInput = Pipe()
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
