import Darwin
import Foundation

public enum ProcessOutputChannel: String, Equatable, Sendable {
  case standardError
  case standardOutput
}

public struct ProcessOutputEvent: Equatable, Sendable {
  public let bytes: Data
  public let channel: ProcessOutputChannel
  public let sequence: UInt64

  public init(bytes: Data, channel: ProcessOutputChannel, sequence: UInt64) {
    self.bytes = bytes
    self.channel = channel
    self.sequence = sequence
  }
}

public struct ProcessOutputLimits: Equatable, Sendable {
  public let maximumBufferedEvents: Int
  public let maximumBytesPerChannel: Int
  public let maximumChunkBytes: Int
  public let outputDrainGrace: TimeInterval
  public let violationKillGrace: TimeInterval

  public init(
    maximumBufferedEvents: Int = 128,
    maximumBytesPerChannel: Int = 16 * 1024 * 1024,
    maximumChunkBytes: Int = 64 * 1024,
    outputDrainGrace: TimeInterval = 2,
    violationKillGrace: TimeInterval = 0.25
  ) {
    self.maximumBufferedEvents = maximumBufferedEvents
    self.maximumBytesPerChannel = maximumBytesPerChannel
    self.maximumChunkBytes = maximumChunkBytes
    self.outputDrainGrace = outputDrainGrace
    self.violationKillGrace = violationKillGrace
  }

  fileprivate var isValid: Bool {
    maximumBufferedEvents > 0
      && maximumBytesPerChannel > 0
      && maximumChunkBytes > 0
      && maximumChunkBytes <= maximumBytesPerChannel
      && outputDrainGrace >= 0
      && violationKillGrace >= 0
  }
}

public enum ProcessTermination: Equatable, Sendable {
  case exited(status: Int32)
  case signalled(signal: Int32)
}

public enum ProcessOutputDisposition: Equatable, Sendable {
  case complete
  case bufferLimitExceeded(ProcessOutputChannel)
  case byteLimitExceeded(ProcessOutputChannel)
  case consumerStopped(ProcessOutputChannel)
  case drainTimedOut
  case readFailed(ProcessOutputChannel, errno: Int32)
}

public struct ProcessCompletion: Equatable, Sendable {
  public let cancellationRequested: Bool
  public let processGroupID: pid_t
  public let processIdentifier: pid_t
  public let standardErrorBytes: Int
  public let standardOutputBytes: Int
  public let outputDisposition: ProcessOutputDisposition
  public let termination: ProcessTermination

  public var succeeded: Bool {
    termination == .exited(status: 0) && outputDisposition == .complete
  }
}

public enum SignalDeliveryOutcome: Equatable, Sendable {
  case delivered
  case failed(errno: Int32)
  case notRequested
  case processGroupMissing
}

public struct ProcessCancellationReceipt: Equatable, Sendable {
  public let completion: ProcessCompletion
  public let kill: SignalDeliveryOutcome
  public let term: SignalDeliveryOutcome
}

public enum ProcessLaunchError: LocalizedError, Equatable, Sendable {
  case adapterArgumentsAreNotEmpty
  case adapterIsNotExecutable(String)
  case failedToCreateProcessGroup(pid_t)
  case invalidEnvironmentKey(String)
  case invalidOutputLimits
  case invalidWorkingDirectory(String)
  case launchFailed(String)

  public var errorDescription: String? {
    switch self {
    case .adapterArgumentsAreNotEmpty:
      return "The generated adapter must be launched with an empty argument vector."
    case .adapterIsNotExecutable(let path):
      return "The generated adapter is not executable: \(path)"
    case .failedToCreateProcessGroup(let pid):
      return "The generated adapter process \(pid) did not enter its owned process group."
    case .invalidEnvironmentKey(let key):
      return "The adapter environment contains an unsafe key: \(key)"
    case .invalidOutputLimits:
      return "Process output limits are invalid."
    case .invalidWorkingDirectory(let path):
      return "The adapter working directory is invalid: \(path)"
    case .launchFailed(let description):
      return "The generated adapter could not be launched: \(description)"
    }
  }
}

public protocol OwnedProcess: Sendable {
  var events: AsyncStream<ProcessOutputEvent> { get }

  func cancel(gracePeriod: TimeInterval) async -> ProcessCancellationReceipt
  func wait() async -> ProcessCompletion
}

public protocol ProcessSupervising: Sendable {
  func spawn(_ invocation: AdapterInvocation) throws -> any OwnedProcess
}

public struct OwnedProcessSupervisor: ProcessSupervising, Sendable {
  public let limits: ProcessOutputLimits

  public init(limits: ProcessOutputLimits = ProcessOutputLimits()) {
    self.limits = limits
  }

  public func spawn(_ invocation: AdapterInvocation) throws -> any OwnedProcess {
    guard limits.isValid else { throw ProcessLaunchError.invalidOutputLimits }
    guard invocation.arguments.isEmpty else {
      throw ProcessLaunchError.adapterArgumentsAreNotEmpty
    }
    guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
      throw ProcessLaunchError.adapterIsNotExecutable(invocation.executableURL.path)
    }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: invocation.workingDirectoryURL.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      throw ProcessLaunchError.invalidWorkingDirectory(invocation.workingDirectoryURL.path)
    }
    for key in invocation.environment.keys where !BuildProxySecurity.isEnvironmentKey(key) {
      throw ProcessLaunchError.invalidEnvironmentKey(key)
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let process = Process()
    let processTermination = DispatchSemaphore(value: 0)
    process.executableURL = invocation.executableURL
    process.arguments = []
    process.currentDirectoryURL = invocation.workingDirectoryURL
    process.environment = invocation.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.terminationHandler = { _ in processTermination.signal() }

    let startsNewProcessGroup = Selector(("setStartsNewProcessGroup:"))
    guard process.responds(to: startsNewProcessGroup) else {
      throw ProcessLaunchError.failedToCreateProcessGroup(0)
    }
    process.setValue(true, forKey: "startsNewProcessGroup")

    do {
      try process.run()
    } catch {
      throw ProcessLaunchError.launchFailed(error.localizedDescription)
    }
    let processIdentifier = process.processIdentifier
    let observedProcessGroup = getpgid(processIdentifier)
    let exitedBeforeObservation = observedProcessGroup == -1 && errno == ESRCH && !process.isRunning
    guard observedProcessGroup == processIdentifier || exitedBeforeObservation else {
      process.terminate()
      processTermination.wait()
      throw ProcessLaunchError.failedToCreateProcessGroup(processIdentifier)
    }

    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
    return OwnedAdapterProcess(
      process: process,
      processTermination: processTermination,
      standardOutput: outputPipe.fileHandleForReading,
      standardError: errorPipe.fileHandleForReading,
      limits: limits
    )
  }
}

private final class OwnedAdapterProcess: OwnedProcess, @unchecked Sendable {
  private struct State {
    var cancellationRequested = false
    var completion: ProcessCompletion?
    var kill: SignalDeliveryOutcome = .notRequested
    var outputDisposition: ProcessOutputDisposition = .complete
    var sequence: UInt64 = 0
    var standardErrorBytes = 0
    var standardOutputBytes = 0
    var stopReaders = false
    var term: SignalDeliveryOutcome = .notRequested
    var waiters = [CheckedContinuation<ProcessCompletion, Never>]()
  }

  let events: AsyncStream<ProcessOutputEvent>

  private let continuation: AsyncStream<ProcessOutputEvent>.Continuation
  private let emissionLock = NSLock()
  private let limits: ProcessOutputLimits
  private let lock = NSLock()
  private let process: Process
  private let processGroupID: pid_t
  private let processTermination: DispatchSemaphore
  private let readers = DispatchGroup()
  private let standardError: FileHandle
  private let standardOutput: FileHandle
  private var state = State()

  init(
    process: Process,
    processTermination: DispatchSemaphore,
    standardOutput: FileHandle,
    standardError: FileHandle,
    limits: ProcessOutputLimits
  ) {
    self.process = process
    processGroupID = process.processIdentifier
    self.processTermination = processTermination
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.limits = limits

    var capturedContinuation: AsyncStream<ProcessOutputEvent>.Continuation?
    events = AsyncStream(bufferingPolicy: .bufferingOldest(limits.maximumBufferedEvents)) {
      capturedContinuation = $0
    }
    continuation = capturedContinuation!

    startReader(standardOutput, channel: .standardOutput)
    startReader(standardError, channel: .standardError)
    startMonitor()
  }

  func wait() async -> ProcessCompletion {
    await withCheckedContinuation { continuation in
      let result = lock.withLock { () -> ProcessCompletion? in
        if let completion = state.completion {
          return completion
        }
        state.waiters.append(continuation)
        return nil
      }
      if let result {
        continuation.resume(returning: result)
      }
    }
  }

  func cancel(gracePeriod: TimeInterval) async -> ProcessCancellationReceipt {
    let shouldSignal = lock.withLock { () -> Bool in
      guard state.completion == nil else { return false }
      let firstRequest = !state.cancellationRequested
      state.cancellationRequested = true
      return firstRequest
    }
    if shouldSignal {
      let term = deliver(SIGTERM)
      lock.withLock { state.term = term }
      if term == .delivered {
        scheduleKill(after: max(0, gracePeriod))
      }
    }
    let completion = await wait()
    return lock.withLock {
      ProcessCancellationReceipt(
        completion: completion,
        kill: state.kill,
        term: state.term
      )
    }
  }

  private func startReader(_ handle: FileHandle, channel: ProcessOutputChannel) {
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { self.readers.leave() }
      var buffer = [UInt8](repeating: 0, count: self.limits.maximumChunkBytes)
      var descriptor = pollfd(
        fd: handle.fileDescriptor,
        events: Int16(POLLIN | POLLHUP | POLLERR),
        revents: 0
      )
      while !self.lock.withLock({ self.state.stopReaders }) {
        descriptor.revents = 0
        let pollResult = Darwin.poll(&descriptor, 1, 100)
        if pollResult == 0 { continue }
        if pollResult < 0 {
          if errno == EINTR { continue }
          self.recordOutputViolation(.readFailed(channel, errno: errno))
          return
        }
        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
        if count == 0 { return }
        if count < 0 {
          if errno == EINTR { continue }
          if errno != EBADF {
            self.recordOutputViolation(.readFailed(channel, errno: errno))
          }
          return
        }
        let data = Data(bytes: buffer, count: count)
        guard self.recordByteCount(count, channel: channel) else { continue }
        let yieldResult = self.emissionLock.withLock {
          let sequence = self.lock.withLock { () -> UInt64 in
            self.state.sequence += 1
            return self.state.sequence
          }
          return self.continuation.yield(
            ProcessOutputEvent(bytes: data, channel: channel, sequence: sequence)
          )
        }
        switch yieldResult {
        case .enqueued:
          break
        case .dropped:
          self.recordOutputViolation(.bufferLimitExceeded(channel))
        case .terminated:
          self.recordOutputViolation(.consumerStopped(channel))
        @unknown default:
          self.recordOutputViolation(.bufferLimitExceeded(channel))
        }
      }
    }
  }

  private func startMonitor() {
    DispatchQueue.global(qos: .utility).async {
      self.processTermination.wait()
      let deadline = DispatchTime.now() + self.limits.outputDrainGrace
      if self.readers.wait(timeout: deadline) == .timedOut {
        self.recordOutputViolation(.drainTimedOut)
        _ = self.deliver(SIGKILL, recordingKill: true)
        self.lock.withLock { self.state.stopReaders = true }
        _ = self.readers.wait(timeout: .now() + 1)
        try? self.standardOutput.close()
        try? self.standardError.close()
      }
      self.continuation.finish()
      self.complete()
    }
  }

  private func recordByteCount(_ count: Int, channel: ProcessOutputChannel) -> Bool {
    let exceeded = lock.withLock { () -> Bool in
      switch channel {
      case .standardOutput:
        guard count <= limits.maximumBytesPerChannel - state.standardOutputBytes else {
          return true
        }
        state.standardOutputBytes += count
      case .standardError:
        guard count <= limits.maximumBytesPerChannel - state.standardErrorBytes else {
          return true
        }
        state.standardErrorBytes += count
      }
      return false
    }
    if exceeded {
      recordOutputViolation(.byteLimitExceeded(channel))
      return false
    }
    return true
  }

  private func recordOutputViolation(_ violation: ProcessOutputDisposition) {
    let isFirstViolation = lock.withLock { () -> Bool in
      guard state.outputDisposition == .complete else { return false }
      state.outputDisposition = violation
      return true
    }
    guard isFirstViolation else { return }
    let term = deliver(SIGTERM)
    lock.withLock {
      if state.term == .notRequested {
        state.term = term
      }
    }
    if term == .delivered {
      scheduleKill(after: limits.violationKillGrace)
    }
  }

  private func scheduleKill(after gracePeriod: TimeInterval) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) {
      let shouldTry = self.lock.withLock { self.state.completion == nil }
      if shouldTry {
        _ = self.deliver(SIGKILL, recordingKill: true)
      }
    }
  }

  @discardableResult
  private func deliver(_ signal: Int32, recordingKill: Bool = false) -> SignalDeliveryOutcome {
    let result: SignalDeliveryOutcome
    if kill(-processGroupID, signal) == 0 {
      result = .delivered
    } else if errno == ESRCH {
      result = .processGroupMissing
    } else {
      result = .failed(errno: errno)
    }
    if recordingKill {
      lock.withLock {
        if state.kill == .notRequested {
          state.kill = result
        }
      }
    }
    return result
  }

  private func complete() {
    let termination: ProcessTermination
    switch process.terminationReason {
    case .exit:
      termination = .exited(status: process.terminationStatus)
    case .uncaughtSignal:
      termination = .signalled(signal: process.terminationStatus)
    @unknown default:
      termination = .exited(status: process.terminationStatus)
    }
    let waiters = lock.withLock { () -> [CheckedContinuation<ProcessCompletion, Never>] in
      let completion = ProcessCompletion(
        cancellationRequested: state.cancellationRequested,
        processGroupID: processGroupID,
        processIdentifier: process.processIdentifier,
        standardErrorBytes: state.standardErrorBytes,
        standardOutputBytes: state.standardOutputBytes,
        outputDisposition: state.outputDisposition,
        termination: termination
      )
      state.completion = completion
      let waiters = state.waiters
      state.waiters.removeAll()
      return waiters
    }
    let completion = lock.withLock { state.completion! }
    for waiter in waiters {
      waiter.resume(returning: completion)
    }
  }
}

extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
