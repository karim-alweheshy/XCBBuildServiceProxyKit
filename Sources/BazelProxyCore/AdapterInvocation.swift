import Foundation

public enum AdapterInvocationError: LocalizedError, Equatable, Sendable {
  case invalidOperationID(String)
  case invalidWorkspace(String)
  case unsafeOperationRoot(String)
  case unsafeAdapter(String)
  case adapterIsNotExecutable(String)
  case undeclaredEnvironmentKey(String)
  case unsafeEnvironmentValue(String)
  case unsafeRequestValue(String)
  case fileSystem(String)

  public var errorDescription: String? {
    switch self {
    case .invalidOperationID(let value):
      return "The operation ID is unsafe: \(value)"
    case .invalidWorkspace(let path):
      return "The workspace is not an existing directory: \(path)"
    case .unsafeOperationRoot(let path):
      return "The adapter operation root is unsafe: \(path)"
    case .unsafeAdapter(let path):
      return "The generated adapter path is unsafe: \(path)"
    case .adapterIsNotExecutable(let path):
      return "The generated adapter is not an executable regular file: \(path)"
    case .undeclaredEnvironmentKey(let key):
      return "The bridge supplied an environment value not declared by the manifest: \(key)"
    case .unsafeEnvironmentValue(let key):
      return "The adapter environment contains a credential-shaped value for \(key)."
    case .unsafeRequestValue(let value):
      return "The adapter request contains an unsafe value: \(value)"
    case .fileSystem(let description):
      return "The adapter invocation could not be prepared: \(description)"
    }
  }
}

public struct AdapterInvocation: Equatable, Sendable {
  public let actionGraphURL: URL
  public let arguments: [String]
  public let bepURL: URL
  public let environment: [String: String]
  public let executableURL: URL
  public let operationDirectoryURL: URL
  public let receiptURL: URL
  public let requestDirectoryURL: URL
  public let workingDirectoryURL: URL

  public func removeTemporaryFiles(fileManager: FileManager = .default) throws {
    try fileManager.removeItem(at: operationDirectoryURL)
  }
}

public struct AdapterInvocationFactory: Sendable {
  public static let actionGraphEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_ACTION_GRAPH_PATH"
  public static let bepEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_BEP_PATH"
  public static let receiptEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"
  public static let requestDirectoryEnvironmentKey = "SWIFTBUILD_BAZEL_PROXY_REQUEST_DIR"

  public static let systemEnvironmentAllowlist: Set<String> = [
    "HOME", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "PATH", "SSH_AUTH_SOCK", "TERM", "TMPDIR",
    "USER", "http_proxy", "https_proxy", "no_proxy",
  ]

  public let operationRootURL: URL

  public init(
    operationRootURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xcode-bazel-proxy",
      isDirectory: true
    )
  ) {
    self.operationRootURL = operationRootURL
  }

  public func make(
    for plan: ResolvedBuildPlan,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> AdapterInvocation {
    try validateOperationID(plan.operationID)
    let workspaceURL = plan.intent.workspaceURL.standardizedFileURL
    try validateDirectory(
      workspaceURL, error: .invalidWorkspace(workspaceURL.path), fileManager: fileManager)
    let adapterURL = try resolveAdapter(for: plan, fileManager: fileManager)
    let environment = try makeEnvironment(
      manifest: plan.manifest,
      evaluated: plan.evaluatedEnvironment,
      processEnvironment: processEnvironment
    )

    let rootURL = try prepareOperationRoot(fileManager: fileManager)
    let operationURL = rootURL.appendingPathComponent(plan.operationID, isDirectory: true)
    let requestURL = operationURL.appendingPathComponent("request", isDirectory: true)
    do {
      guard !fileManager.fileExists(atPath: operationURL.path) else {
        throw AdapterInvocationError.fileSystem(
          "operation directory already exists: \(operationURL.path)")
      }
      try createDirectory(operationURL, permissions: 0o700, fileManager: fileManager)
      try createDirectory(requestURL, permissions: 0o700, fileManager: fileManager)

      try writeRequestFile(
        plan.adapterRequest.labels,
        named: "labels",
        in: requestURL,
        fileManager: fileManager
      )
      try writeRequestFile(
        plan.adapterRequest.targetIDs,
        named: "target_ids",
        in: requestURL,
        fileManager: fileManager
      )
      try writeRequestFile(
        plan.adapterRequest.outputGroups,
        named: "output_groups",
        in: requestURL,
        fileManager: fileManager
      )

      let actionGraphURL = operationURL.appendingPathComponent("configured-actions.json")
      let bepURL = operationURL.appendingPathComponent("build-event.jsonl")
      let receiptURL = operationURL.appendingPathComponent("invocation-receipt.json")
      var finalEnvironment = environment
      finalEnvironment[Self.actionGraphEnvironmentKey] = actionGraphURL.path
      finalEnvironment[Self.requestDirectoryEnvironmentKey] = requestURL.path
      finalEnvironment[Self.bepEnvironmentKey] = bepURL.path
      finalEnvironment[Self.receiptEnvironmentKey] = receiptURL.path

      return AdapterInvocation(
        actionGraphURL: actionGraphURL,
        arguments: [],
        bepURL: bepURL,
        environment: finalEnvironment,
        executableURL: adapterURL,
        operationDirectoryURL: operationURL,
        receiptURL: receiptURL,
        requestDirectoryURL: requestURL,
        workingDirectoryURL: workspaceURL
      )
    } catch {
      try? fileManager.removeItem(at: operationURL)
      throw error
    }
  }

  private func prepareOperationRoot(fileManager: FileManager) throws -> URL {
    guard operationRootURL.isFileURL else {
      throw AdapterInvocationError.unsafeOperationRoot(operationRootURL.absoluteString)
    }
    let rootURL = operationRootURL.standardizedFileURL
    if fileManager.fileExists(atPath: rootURL.path) {
      let attributes = try attributes(at: rootURL, fileManager: fileManager)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        rootURL.resolvingSymlinksInPath().standardizedFileURL == rootURL
      else {
        throw AdapterInvocationError.unsafeOperationRoot(rootURL.path)
      }
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    } else {
      do {
        try createDirectory(rootURL, permissions: 0o700, fileManager: fileManager)
      } catch {
        throw AdapterInvocationError.fileSystem(error.localizedDescription)
      }
    }
    return rootURL
  }

  private func resolveAdapter(
    for plan: ResolvedBuildPlan,
    fileManager: FileManager
  ) throws -> URL {
    let containerURL = plan.intent.projectContainerURL.standardizedFileURL
    let expectedContainer = plan.manifest.project.containerName
    guard containerURL.lastPathComponent == expectedContainer else {
      throw AdapterInvocationError.unsafeAdapter(containerURL.path)
    }
    do {
      try BuildProxySecurity.validateRelativePath(
        plan.manifest.invocation.adapterPath,
        field: "invocation.adapterPath"
      )
    } catch {
      throw AdapterInvocationError.unsafeAdapter(plan.manifest.invocation.adapterPath)
    }

    let physicalContainer = containerURL.resolvingSymlinksInPath().standardizedFileURL
    let lexicalAdapter =
      containerURL
      .appendingPathComponent(plan.manifest.invocation.adapterPath, isDirectory: false)
      .standardizedFileURL
    let physicalAdapter = lexicalAdapter.resolvingSymlinksInPath().standardizedFileURL
    let expectedPhysicalAdapter =
      physicalContainer
      .appendingPathComponent(plan.manifest.invocation.adapterPath, isDirectory: false)
      .standardizedFileURL
    guard physicalAdapter == expectedPhysicalAdapter else {
      throw AdapterInvocationError.unsafeAdapter(lexicalAdapter.path)
    }

    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: lexicalAdapter.path)
    } catch {
      throw AdapterInvocationError.unsafeAdapter(lexicalAdapter.path)
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      fileManager.isExecutableFile(atPath: lexicalAdapter.path)
    else {
      throw AdapterInvocationError.adapterIsNotExecutable(lexicalAdapter.path)
    }
    return physicalAdapter
  }

  private func makeEnvironment(
    manifest: BuildProxyManifest,
    evaluated: [String: String],
    processEnvironment: [String: String]
  ) throws -> [String: String] {
    let declaredKeys = Set(manifest.invocation.environmentKeys)
    for key in evaluated.keys.sorted() {
      guard declaredKeys.contains(key) else {
        throw AdapterInvocationError.undeclaredEnvironmentKey(key)
      }
      guard !BuildProxySecurity.isSensitiveEnvironmentKey(key) else {
        throw AdapterInvocationError.undeclaredEnvironmentKey(key)
      }
    }

    var result = [String: String]()
    for key in Self.systemEnvironmentAllowlist.sorted() {
      guard let value = processEnvironment[key] else { continue }
      try validateEnvironmentValue(value, for: key)
      result[key] = value
    }
    for key in evaluated.keys.sorted() {
      guard let value = evaluated[key] else { continue }
      try validateEnvironmentValue(value, for: key)
      result[key] = value
    }
    return result
  }

  private func validateEnvironmentValue(_ value: String, for key: String) throws {
    guard !BuildProxySecurity.hasControlCharacters(value),
      !BuildProxySecurity.containsSensitiveEnvironmentValue(value)
    else {
      throw AdapterInvocationError.unsafeEnvironmentValue(key)
    }
  }

  private func validateOperationID(_ value: String) throws {
    guard !value.isEmpty,
      value != ".",
      value != "..",
      !value.contains("/"),
      !BuildProxySecurity.hasControlCharacters(value)
    else {
      throw AdapterInvocationError.invalidOperationID(value)
    }
  }

  private func validateDirectory(
    _ url: URL,
    error: AdapterInvocationError,
    fileManager: FileManager
  ) throws {
    guard url.isFileURL else { throw error }
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw error
    }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw error }
  }

  private func createDirectory(
    _ url: URL,
    permissions: Int,
    fileManager: FileManager
  ) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: permissions]
    )
    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  private func writeRequestFile(
    _ values: [String],
    named name: String,
    in directoryURL: URL,
    fileManager: FileManager
  ) throws {
    for value in values where value.isEmpty || BuildProxySecurity.hasControlCharacters(value) {
      throw AdapterInvocationError.unsafeRequestValue(value)
    }
    let contents = Array(Set(values)).sorted().joined(separator: "\n") + "\n"
    guard let data = contents.data(using: .utf8) else {
      throw AdapterInvocationError.fileSystem("request file is not UTF-8")
    }
    let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
    guard
      fileManager.createFile(
        atPath: fileURL.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw AdapterInvocationError.fileSystem("could not create \(fileURL.path)")
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func attributes(
    at url: URL,
    fileManager: FileManager
  ) throws -> [FileAttributeKey: Any] {
    do {
      return try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw AdapterInvocationError.unsafeOperationRoot(url.path)
    }
  }
}
