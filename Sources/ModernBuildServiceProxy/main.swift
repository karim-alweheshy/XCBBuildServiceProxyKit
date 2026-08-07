import Darwin
import Foundation
import ModernBuildServiceProxyCore

private let softwareConfigurationError: Int32 = 78

do {
  let resolution = try NativeBuildServiceResolver.resolve()

  if CommandLine.arguments.dropFirst() == ["--resolve-native-service"] {
    print(resolution.serviceExecutableURL.path)
    exit(EXIT_SUCCESS)
  }
  if CommandLine.arguments.count != 1 {
    FileHandle.standardError.write(Data("ModernBuildServiceProxy: unsupported arguments\n".utf8))
    exit(softwareConfigurationError)
  }

  let childEnvironment = NativeBuildServiceResolver.sanitizedChildEnvironment(
    developerURL: resolution.developerURL
  )
  let metadataRecorder = try ProcessInfo.processInfo.environment["XCBPROXY_METADATA_PATH"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: false) }
    .map(BuildServiceFrameMetadataRecorder.init(fileURL:))
  let relay = OpaquePipeRelay(
    executableURL: resolution.serviceExecutableURL,
    environment: childEnvironment,
    metadataRecorder: metadataRecorder
  )

  let signalQueue = DispatchQueue(label: "ModernBuildServiceProxy.signals")
  var signalSources: [DispatchSourceSignal] = []

  let summary = try relay.run {
    // Install proxy signal handling only after the native service launches.
    // SIG_IGN survives exec, so installing it earlier would make the child
    // service ignore the same termination signals.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    signalSources = [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
      source.setEventHandler { relay.requestStop() }
      source.resume()
      return source
    }
  }
  withExtendedLifetime(signalSources) {}

  if ProcessInfo.processInfo.environment["XCBPROXY_LOG_SUMMARY"] == "1" {
    let line =
      "ModernBuildServiceProxy: client_to_service_bytes=\(summary.clientToServiceBytes) service_to_client_bytes=\(summary.serviceToClientBytes) child_status=\(summary.terminationStatus)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
  exit(summary.terminationStatus)
} catch {
  let message = "ModernBuildServiceProxy: \(error.localizedDescription)\n"
  FileHandle.standardError.write(Data(message.utf8))
  exit(softwareConfigurationError)
}
