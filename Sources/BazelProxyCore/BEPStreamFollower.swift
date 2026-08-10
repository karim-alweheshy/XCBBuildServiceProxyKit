import Darwin
import Foundation

/// Follows one Bazel JSONL build-event file while its owning adapter is running.
///
/// The follower pins one no-follow regular-file descriptor, incrementally validates every byte,
/// and verifies that the published path still names the same inode before accepting the terminal
/// result. A missing file is retried only while the adapter is still running.
public struct BEPStreamFollower: Sendable {
  public typealias CompletionProbe = @Sendable () async -> Bool
  public typealias EventHandler = @Sendable (BEPEvent) async throws -> Void

  private let limits: BEPStreamLimits
  private let pollInterval: Duration

  public init(
    limits: BEPStreamLimits = BEPStreamLimits(),
    pollInterval: Duration = .milliseconds(10)
  ) {
    self.limits = limits
    self.pollInterval = pollInterval
  }

  public func follow(
    fileAt url: URL,
    processIsComplete: @escaping CompletionProbe,
    onEvent: @escaping EventHandler
  ) async throws -> BEPValidation {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw BEPStreamError.unsafeFile(url.absoluteString)
    }

    var descriptor: Int32?
    var identity: FileIdentity?
    var validator = try BEPStreamValidator(limits: limits)
    var events = [BEPEvent]()
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limits.maximumFileBytes))
    defer {
      if let descriptor { Darwin.close(descriptor) }
    }

    while true {
      try Task.checkCancellation()
      let processComplete = await processIsComplete()

      if descriptor == nil {
        switch try openIfPresent(url) {
        case .missing where processComplete:
          throw BEPStreamError.unsafeFile(url.path)
        case .missing:
          try await Task.sleep(for: pollInterval)
          continue
        case .opened(let openedDescriptor, let openedIdentity):
          descriptor = openedDescriptor
          identity = openedIdentity
        }
      }

      guard let descriptor else { continue }
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
          if errno == EINTR { continue }
          throw BEPStreamError.readFailed(errno: errno)
        }
        let parsed = try validator.consume(Data(buffer.prefix(count)))
        events.append(contentsOf: parsed)
        for event in parsed {
          try await onEvent(event)
        }
      }

      if processComplete {
        guard let identity, pathStillNamesIdentity(url, identity: identity) else {
          throw BEPStreamError.unsafeFile(url.path)
        }
        let finalization = try validator.finishWithEvents()
        events.append(contentsOf: finalization.events)
        for event in finalization.events {
          try await onEvent(event)
        }
        return BEPValidation(events: events, result: finalization.result)
      }

      try await Task.sleep(for: pollInterval)
    }
  }

  private func openIfPresent(_ url: URL) throws -> OpenResult {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    if descriptor < 0 {
      if errno == ENOENT { return .missing }
      throw BEPStreamError.unsafeFile(url.path)
    }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0,
      status.st_size <= limits.maximumFileBytes
    else {
      Darwin.close(descriptor)
      throw BEPStreamError.unsafeFile(url.path)
    }
    return .opened(
      descriptor,
      FileIdentity(device: status.st_dev, inode: status.st_ino)
    )
  }

  private func pathStillNamesIdentity(_ url: URL, identity: FileIdentity) -> Bool {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    return result == 0
      && status.st_mode & S_IFMT == S_IFREG
      && status.st_dev == identity.device
      && status.st_ino == identity.inode
  }
}

private enum OpenResult {
  case missing
  case opened(Int32, FileIdentity)
}

private struct FileIdentity {
  let device: dev_t
  let inode: ino_t
}
