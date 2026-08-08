import Darwin
import Foundation

public enum OpaquePipeRelayError: LocalizedError {
  case failedToCreateProcessGroup(pid_t)
  case relayFailed(direction: String, underlying: String)

  public var errorDescription: String? {
    switch self {
    case .failedToCreateProcessGroup(let pid):
      return "The native build service process \(pid) did not start in an owned process group."
    case .relayFailed(let direction, let underlying):
      return "The \(direction) build-service relay failed: \(underlying)"
    }
  }
}

/// Relays complete build-service frames without decoding or rewriting payloads.
///
/// The fixed outer header is validated to bound reads, while every accepted
/// header and payload byte is forwarded unchanged. Unknown protocol messages,
/// fields, and noncanonical payload encodings therefore remain transparent.
public final class OpaquePipeRelay {
  public struct Summary: Equatable {
    public let clientToServiceBytes: UInt64
    public let serviceToClientBytes: UInt64
    public let terminationStatus: Int32

    public init(
      clientToServiceBytes: UInt64,
      serviceToClientBytes: UInt64,
      terminationStatus: Int32
    ) {
      self.clientToServiceBytes = clientToServiceBytes
      self.serviceToClientBytes = serviceToClientBytes
      self.terminationStatus = terminationStatus
    }
  }

  private let executableURL: URL
  private let environment: [String: String]
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let terminationGrace: TimeInterval
  private let metadataRecorder: BuildServiceFrameMetadataRecorder?
  private let frameInterceptor: (any BuildServiceFrameInterceptor)?
  private let lock = NSLock()
  private var process: Process?
  private var stopRequested = false

  public init(
    executableURL: URL,
    environment: [String: String],
    input: FileHandle = .standardInput,
    output: FileHandle = .standardOutput,
    errorOutput: FileHandle = .standardError,
    terminationGrace: TimeInterval = 2,
    metadataRecorder: BuildServiceFrameMetadataRecorder? = nil,
    frameInterceptor: (any BuildServiceFrameInterceptor)? = nil
  ) {
    self.executableURL = executableURL
    self.environment = environment
    self.input = input
    self.output = output
    self.errorOutput = errorOutput
    self.terminationGrace = terminationGrace
    self.metadataRecorder = metadataRecorder
    self.frameInterceptor = frameInterceptor
  }

  public func run(onProcessStarted: (() -> Void)? = nil) throws -> Summary {
    let childInput = Pipe()
    let childOutput = Pipe()
    let child = Process()
    child.executableURL = executableURL
    child.currentDirectoryURL = executableURL.deletingLastPathComponent()
    child.environment = environment
    child.standardInput = childInput
    child.standardOutput = childOutput
    child.standardError = errorOutput

    let startsNewProcessGroup = Selector(("setStartsNewProcessGroup:"))
    guard child.responds(to: startsNewProcessGroup) else {
      throw OpaquePipeRelayError.failedToCreateProcessGroup(0)
    }
    // Foundation exposes this Process control through Objective-C KVC on
    // macOS. KVC is required because perform(_:with:) cannot correctly
    // marshal the primitive BOOL argument.
    child.setValue(true, forKey: "startsNewProcessGroup")

    try child.run()
    let childPID = child.processIdentifier
    guard getpgid(childPID) == childPID else {
      child.terminate()
      throw OpaquePipeRelayError.failedToCreateProcessGroup(childPID)
    }

    lock.withLock {
      process = child
      if stopRequested {
        signalOwnedProcessGroup(SIGTERM)
      }
    }
    onProcessStarted?()

    let copyGroup = DispatchGroup()
    let countLock = NSLock()
    let failureLatch = FirstErrorLatch<OpaquePipeRelayError>()
    var clientToServiceBytes: UInt64 = 0
    var serviceToClientBytes: UInt64 = 0

    let recordFailure: (OpaquePipeRelayError) -> Void = { [weak self] failure in
      guard failureLatch.record(failure) else { return }
      self?.requestStop()
    }
    let toNative = SerializedFrameSink(
      writer: FileDescriptorFrameWriter(
        descriptor: childInput.fileHandleForWriting.fileDescriptor
      ),
      onFirstFailure: { [weak self] error in
        guard let self, !self.isStopRequested else { return }
        recordFailure(
          .relayFailed(
            direction: "client-to-service",
            underlying: error.localizedDescription
          )
        )
      }
    )
    let toXcode = SerializedFrameSink(
      writer: FileDescriptorFrameWriter(descriptor: output.fileDescriptor),
      onFirstFailure: { [weak self] error in
        guard let self, !self.isStopRequested else { return }
        recordFailure(
          .relayFailed(
            direction: "service-to-client",
            underlying: error.localizedDescription
          )
        )
      }
    )
    let outputs = BuildServiceFrameOutputs(
      sendToNative: toNative.send,
      sendToXcode: toXcode.send
    )

    copyGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        try? childInput.fileHandleForWriting.close()
        copyGroup.leave()
      }
      do {
        let summary = try BuildServiceFramePump(
          direction: .clientToService,
          reader: FileDescriptorFrameReader(descriptor: self.input.fileDescriptor),
          sink: toNative,
          recorder: self.metadataRecorder,
          interceptor: self.frameInterceptor,
          outputs: outputs
        ).run()
        countLock.withLock { clientToServiceBytes = summary.byteCount }
      } catch {
        if !self.isStopRequested {
          recordFailure(
            .relayFailed(
              direction: "client-to-service",
              underlying: error.localizedDescription
            )
          )
        }
      }
    }

    copyGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { copyGroup.leave() }
      do {
        let summary = try BuildServiceFramePump(
          direction: .serviceToClient,
          reader: FileDescriptorFrameReader(
            descriptor: childOutput.fileHandleForReading.fileDescriptor),
          sink: toXcode,
          recorder: self.metadataRecorder,
          interceptor: self.frameInterceptor,
          outputs: outputs
        ).run()
        countLock.withLock { serviceToClientBytes = summary.byteCount }
      } catch {
        if !self.isStopRequested {
          recordFailure(
            .relayFailed(
              direction: "service-to-client",
              underlying: error.localizedDescription
            )
          )
        }
      }
    }

    child.waitUntilExit()
    try? childInput.fileHandleForWriting.close()
    let copyResult = copyGroup.wait(timeout: .now() + terminationGrace)
    lock.withLock { process = nil }

    if let relayError = failureLatch.first {
      throw relayError
    }
    if copyResult == .timedOut {
      throw OpaquePipeRelayError.relayFailed(
        direction: "shutdown",
        underlying: "a relay direction did not drain within the bounded grace period"
      )
    }

    return Summary(
      clientToServiceBytes: countLock.withLock { clientToServiceBytes },
      serviceToClientBytes: countLock.withLock { serviceToClientBytes },
      terminationStatus: child.terminationStatus
    )
  }

  public func requestStop() {
    let childPID: pid_t? = lock.withLock {
      stopRequested = true
      return process?.processIdentifier
    }
    try? input.close()
    guard let childPID else { return }

    kill(-childPID, SIGTERM)
    let grace = terminationGrace
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
      let isSameRunningChild = self.lock.withLock {
        self.process?.processIdentifier == childPID && self.process?.isRunning == true
      }
      if isSameRunningChild {
        kill(-childPID, SIGKILL)
      }
    }
  }

  private func signalOwnedProcessGroup(_ signal: Int32) {
    guard let childPID = process?.processIdentifier else { return }
    kill(-childPID, signal)
  }

  private var isStopRequested: Bool {
    lock.withLock { stopRequested }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
