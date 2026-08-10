import CryptoKit
import Darwin
import Foundation

public struct BuildProxyManifestExpectation: Equatable, Sendable {
  public let projectContainerURL: URL
  public let projectIdentity: String?

  public init(projectContainerURL: URL, projectIdentity: String? = nil) {
    self.projectContainerURL = projectContainerURL
    self.projectIdentity = projectIdentity
  }
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

public struct BuildProxyManifestFileIdentity: Equatable, Sendable {
  public let algorithm: String
  public let byteSize: UInt64
  public let hex: String

  public init(algorithm: String, byteSize: UInt64, hex: String) {
    self.algorithm = algorithm
    self.byteSize = byteSize
    self.hex = hex
  }
}

public struct VerifiedBuildProxyManifest: Equatable, Sendable {
  public let manifest: BuildProxyManifest
  public let fileIdentity: BuildProxyManifestFileIdentity

  public init(
    manifest: BuildProxyManifest,
    fileIdentity: BuildProxyManifestFileIdentity
  ) {
    self.manifest = manifest
    self.fileIdentity = fileIdentity
  }
}

public enum BuildProxyManifestError: LocalizedError, Equatable, Sendable {
  case invalidJSON(String)
  case invalidExpectedSHA256(String)
  case invalidShape(String)
  case invalidContract(String)
  case unsupportedSchema(Int)
  case projectContainerMismatch(expected: String, actual: String)
  case projectIdentityMismatch(expected: String, actual: String)
  case unsafeManifestPath(String)
  case symbolicLink(String)
  case unreadableManifest(String)
  case sensitiveEnvironmentKey(String)
  case sha256Mismatch(expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .invalidJSON(let description):
      return "The build proxy manifest is not valid JSON: \(description)"
    case .invalidExpectedSHA256(let digest):
      return "The expected build proxy manifest SHA-256 is invalid: \(digest)"
    case .invalidShape(let description):
      return "The build proxy manifest has an invalid shape: \(description)"
    case .invalidContract(let description):
      return "The build proxy manifest violates schema v2: \(description)"
    case .unsupportedSchema(let version):
      return "Unsupported build proxy manifest schema version \(version)."
    case .projectContainerMismatch(let expected, let actual):
      return "The build proxy manifest belongs to \(actual), not \(expected)."
    case .projectIdentityMismatch(let expected, let actual):
      return "The build proxy manifest identity \(actual) does not match \(expected)."
    case .unsafeManifestPath(let path):
      return "The build proxy manifest is outside its project container: \(path)"
    case .symbolicLink(let path):
      return "The build proxy manifest path contains a symbolic link: \(path)"
    case .unreadableManifest(let path):
      return "The build proxy manifest is missing or unreadable: \(path)"
    case .sensitiveEnvironmentKey(let key):
      return "The build proxy manifest declares a credential-shaped environment key: \(key)"
    case .sha256Mismatch(let expected, let actual):
      return "The build proxy manifest SHA-256 \(actual) does not match \(expected)."
    }
  }
}

/// The strict schema-v2 contract emitted by `rules_xcodeproj`.
public struct BuildProxyManifest: Codable, Equatable, Sendable {
  public struct Capabilities: Codable, Equatable, Sendable {
    public let actions: [String]
  }

  public struct Product: Codable, Equatable, Sendable {
    public enum Materialization: String, Codable, Equatable, Sendable {
      case copyFile = "copy_file"
      case copyTree = "copy_tree"
      case none
    }

    public let basename: String
    public let materialization: Materialization
    public let name: String
    public let path: String?
    public let type: String
  }

  public struct Invocation: Codable, Equatable, Sendable {
    public let adapterPath: String
    public let bazelPath: String
    public let bazelrcPath: String
    public let bazelEnvironmentKeys: [String]?
    public let environmentKeys: [String]
    public let generatorLabel: String
    public let receiptSchemaVersion: Int
  }

  public struct Project: Codable, Equatable, Sendable {
    public let containerName: String
    public let identity: String
  }

  public struct Variant: Codable, Equatable, Sendable {
    public let arch: String
    public let minimumOSVersion: String
    public let platform: String
  }

  public struct Target: Codable, Equatable, Sendable {
    public let action: String
    public let bazelLabel: String
    public let configuration: String
    public let indexOutputGroups: [String]
    public let outputGroup: String
    public let previewOutputGroups: [String]
    public let product: Product
    public let targetID: String
    public let variant: Variant
    public let xcodeTargetGUID: String
  }

  public let capabilities: Capabilities
  public let ignoredXcodeTargetGUIDs: [String]
  public let invocation: Invocation
  public let project: Project
  public let schemaVersion: Int
  public let targets: [Target]

  public static func load(
    from manifestURL: URL,
    expecting expectation: BuildProxyManifestExpectation,
    fileManager: FileManager = .default
  ) throws -> Self {
    try loadVerified(
      from: manifestURL,
      expecting: expectation,
      expectedSHA256: nil,
      fileManager: fileManager
    ).manifest
  }

  /// Reads, hashes, and decodes one descriptor-bound manifest snapshot.
  ///
  /// The launcher-provided digest is checked against the exact bytes passed to
  /// JSON validation and decoding. The path is never reopened between identity
  /// verification and consumption.
  public static func loadVerified(
    from manifestURL: URL,
    expecting expectation: BuildProxyManifestExpectation,
    expectedSHA256: String,
    fileManager: FileManager = .default
  ) throws -> VerifiedBuildProxyManifest {
    try loadVerified(
      from: manifestURL,
      expecting: expectation,
      expectedSHA256: Optional(expectedSHA256),
      fileManager: fileManager
    )
  }

  private static func loadVerified(
    from manifestURL: URL,
    expecting expectation: BuildProxyManifestExpectation,
    expectedSHA256: String?,
    fileManager: FileManager
  ) throws -> VerifiedBuildProxyManifest {
    let securedURL = try secureManifestURL(
      manifestURL,
      projectContainerURL: expectation.projectContainerURL,
      fileManager: fileManager
    )
    if let expectedSHA256, !isSHA256Hex(expectedSHA256) {
      throw BuildProxyManifestError.invalidExpectedSHA256(expectedSHA256)
    }
    let data = try readManifestSnapshot(from: securedURL)
    let observedSHA256 = SHA256.hash(data: data).hexadecimalString
    if let expectedSHA256, observedSHA256 != expectedSHA256 {
      throw BuildProxyManifestError.sha256Mismatch(
        expected: expectedSHA256,
        actual: observedSHA256
      )
    }

    try validateJSONShape(data)

    let manifest: Self
    do {
      manifest = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw BuildProxyManifestError.invalidJSON(error.localizedDescription)
    }
    try manifest.validate(expectation: expectation)
    return VerifiedBuildProxyManifest(
      manifest: manifest,
      fileIdentity: BuildProxyManifestFileIdentity(
        algorithm: "sha256",
        byteSize: UInt64(data.count),
        hex: observedSHA256
      )
    )
  }

  private static func readManifestSnapshot(from url: URL) throws -> Data {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw BuildProxyManifestError.unreadableManifest(url.path)
    }
    defer { Darwin.close(descriptor) }

    var fileStatus = stat()
    let maximumByteCount = 16 * 1024 * 1024
    guard fstat(descriptor, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_size >= 0,
      fileStatus.st_size <= maximumByteCount
    else {
      throw BuildProxyManifestError.unreadableManifest(url.path)
    }

    var data = Data()
    data.reserveCapacity(Int(fileStatus.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw BuildProxyManifestError.unreadableManifest(url.path)
      }
      if count == 0 { break }
      guard data.count + count <= maximumByteCount else {
        throw BuildProxyManifestError.unreadableManifest(url.path)
      }
      data.append(buffer, count: count)
    }
    return data
  }

  private static func isSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private func validate(expectation: BuildProxyManifestExpectation) throws {
    guard schemaVersion == 2 else {
      throw BuildProxyManifestError.unsupportedSchema(schemaVersion)
    }

    let supportedActions = ["build", "clean", "indexbuild", "preview"]
    guard capabilities.actions.count == Set(capabilities.actions).count,
      Set(capabilities.actions) == Set(supportedActions)
    else {
      throw BuildProxyManifestError.invalidContract(
        "capabilities.actions must contain build, clean, indexbuild, and preview exactly once"
      )
    }

    let expectedContainerName = expectation.projectContainerURL.lastPathComponent
    guard project.containerName == expectedContainerName else {
      throw BuildProxyManifestError.projectContainerMismatch(
        expected: expectedContainerName,
        actual: project.containerName
      )
    }
    guard project.containerName.hasSuffix(".xcodeproj"),
      project.containerName == URL(fileURLWithPath: project.containerName).lastPathComponent,
      !project.identity.isEmpty
    else {
      throw BuildProxyManifestError.invalidContract("project identity is incomplete or unsafe")
    }
    if let projectIdentity = expectation.projectIdentity,
      project.identity != projectIdentity
    {
      throw BuildProxyManifestError.projectIdentityMismatch(
        expected: projectIdentity,
        actual: project.identity
      )
    }

    guard invocation.receiptSchemaVersion == 1,
      !invocation.bazelPath.isEmpty,
      !invocation.generatorLabel.isEmpty
    else {
      throw BuildProxyManifestError.invalidContract("invocation metadata is incomplete")
    }
    try BuildProxySecurity.validateRelativePath(
      invocation.adapterPath,
      field: "invocation.adapterPath"
    )
    try BuildProxySecurity.validateRelativePath(
      invocation.bazelrcPath,
      field: "invocation.bazelrcPath"
    )
    for (field, keys) in [
      ("invocation.environmentKeys", invocation.environmentKeys),
      ("invocation.bazelEnvironmentKeys", invocation.bazelEnvironmentKeys ?? []),
    ] {
      guard keys.count == Set(keys).count else {
        throw BuildProxyManifestError.invalidContract("\(field) contains duplicates")
      }
      for key in keys {
        guard BuildProxySecurity.isEnvironmentKey(key) else {
          throw BuildProxyManifestError.invalidContract("invalid environment key \(key)")
        }
        if BuildProxySecurity.isSensitiveEnvironmentKey(key) {
          throw BuildProxyManifestError.sensitiveEnvironmentKey(key)
        }
      }
    }

    guard ignoredXcodeTargetGUIDs.count == Set(ignoredXcodeTargetGUIDs).count,
      ignoredXcodeTargetGUIDs.allSatisfy({
        !$0.isEmpty && !BuildProxySecurity.hasControlCharacters($0)
      })
    else {
      throw BuildProxyManifestError.invalidContract(
        "ignored target GUIDs are invalid or duplicated")
    }

    var mappingKeys = Set<String>()
    var targetGUIDs = Set<String>()
    for target in targets {
      try validate(target: target)
      let mappingKey = [
        target.xcodeTargetGUID,
        target.configuration,
        target.action,
        target.variant.platform,
        target.variant.arch,
        target.variant.minimumOSVersion,
        target.targetID,
      ].joined(separator: "\u{0}")
      guard mappingKeys.insert(mappingKey).inserted else {
        throw BuildProxyManifestError.invalidContract(
          "duplicate target mapping for \(target.xcodeTargetGUID)/\(target.targetID)"
        )
      }
      targetGUIDs.insert(target.xcodeTargetGUID)
    }
    guard Set(ignoredXcodeTargetGUIDs).isDisjoint(with: targetGUIDs) else {
      throw BuildProxyManifestError.invalidContract(
        "an ignored target GUID is also declared as a build target"
      )
    }
  }

  private func validate(target: Target) throws {
    let scalarFields = [
      ("target.action", target.action),
      ("target.bazelLabel", target.bazelLabel),
      ("target.configuration", target.configuration),
      ("target.targetID", target.targetID),
      ("target.variant.arch", target.variant.arch),
      ("target.variant.minimumOSVersion", target.variant.minimumOSVersion),
      ("target.variant.platform", target.variant.platform),
      ("target.xcodeTargetGUID", target.xcodeTargetGUID),
      ("target.product.basename", target.product.basename),
      ("target.product.name", target.product.name),
      ("target.product.type", target.product.type),
    ]
    guard
      scalarFields.allSatisfy({ !$0.1.isEmpty && !BuildProxySecurity.hasControlCharacters($0.1) })
    else {
      throw BuildProxyManifestError.invalidContract("a target contains an empty or unsafe value")
    }
    guard target.action == "build" else {
      throw BuildProxyManifestError.invalidContract(
        "target action \(target.action) is not supported by schema v2"
      )
    }
    guard !target.product.basename.contains("/"),
      target.product.basename != ".",
      target.product.basename != ".."
    else {
      throw BuildProxyManifestError.invalidContract("target product basename is unsafe")
    }

    switch target.product.materialization {
    case .none:
      guard target.product.path == nil else {
        throw BuildProxyManifestError.invalidContract(
          "a non-materialized product must not declare a path"
        )
      }
    case .copyFile, .copyTree:
      guard let productPath = target.product.path else {
        throw BuildProxyManifestError.invalidContract("a materialized product has no path")
      }
      try BuildProxySecurity.validateRelativePath(productPath, field: "target.product.path")
      let components = productPath.split(separator: "/").map(String.init)
      guard components.first == "bazel-out", components.count > 1,
        components.last == target.product.basename
      else {
        throw BuildProxyManifestError.invalidContract(
          "materialized products must match their basename under bazel-out"
        )
      }
    }

    guard target.outputGroup == "bp \(target.targetID)",
      target.indexOutputGroups == ["bc \(target.targetID)", "bi \(target.targetID)"],
      target.previewOutputGroups == [
        "bc \(target.targetID)", "bp \(target.targetID)", "bl \(target.targetID)",
      ]
    else {
      throw BuildProxyManifestError.invalidContract(
        "target output groups do not match target ID \(target.targetID)"
      )
    }
  }

  private static func secureManifestURL(
    _ manifestURL: URL,
    projectContainerURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    guard manifestURL.isFileURL, projectContainerURL.isFileURL else {
      throw BuildProxyManifestError.unsafeManifestPath(manifestURL.absoluteString)
    }

    let lexicalContainer = projectContainerURL.standardizedFileURL
    let lexicalManifest = manifestURL.standardizedFileURL
    guard
      let relativePath = BuildProxySecurity.relativeDescendantPath(
        child: lexicalManifest,
        parent: lexicalContainer
      ),
      !relativePath.isEmpty
    else {
      throw BuildProxyManifestError.unsafeManifestPath(lexicalManifest.path)
    }

    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: lexicalManifest.path)
    } catch {
      throw BuildProxyManifestError.unreadableManifest(lexicalManifest.path)
    }
    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
      throw BuildProxyManifestError.symbolicLink(lexicalManifest.path)
    }

    let physicalContainer = lexicalContainer.resolvingSymlinksInPath().standardizedFileURL
    let expectedPhysicalManifest =
      physicalContainer
      .appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL
    let physicalManifest = lexicalManifest.resolvingSymlinksInPath().standardizedFileURL
    guard expectedPhysicalManifest == physicalManifest else {
      throw BuildProxyManifestError.symbolicLink(lexicalManifest.path)
    }
    return physicalManifest
  }

  private static func validateJSONShape(_ data: Data) throws {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw BuildProxyManifestError.invalidJSON(error.localizedDescription)
    }

    let top = try JSONShape.object(
      value,
      path: "$",
      required: [
        "capabilities", "ignoredXcodeTargetGUIDs", "invocation", "project", "schemaVersion",
        "targets",
      ]
    )
    _ = try JSONShape.object(
      top["capabilities"],
      path: "$.capabilities",
      required: ["actions"]
    )
    _ = try JSONShape.object(
      top["invocation"],
      path: "$.invocation",
      required: [
        "adapterPath", "bazelPath", "bazelrcPath", "environmentKeys", "generatorLabel",
        "receiptSchemaVersion",
      ],
      optional: ["bazelEnvironmentKeys"]
    )
    _ = try JSONShape.object(
      top["project"],
      path: "$.project",
      required: ["containerName", "identity"]
    )

    guard let targets = top["targets"] as? [Any] else {
      throw BuildProxyManifestError.invalidShape("$.targets must be an array")
    }
    for (index, value) in targets.enumerated() {
      let path = "$.targets[\(index)]"
      let target = try JSONShape.object(
        value,
        path: path,
        required: [
          "action", "bazelLabel", "configuration", "indexOutputGroups", "outputGroup",
          "previewOutputGroups", "product", "targetID", "variant", "xcodeTargetGUID",
        ]
      )
      _ = try JSONShape.object(
        target["product"],
        path: "\(path).product",
        required: ["basename", "materialization", "name", "type"],
        optional: ["path"]
      )
      _ = try JSONShape.object(
        target["variant"],
        path: "\(path).variant",
        required: ["arch", "minimumOSVersion", "platform"]
      )
    }
  }
}

private enum JSONShape {
  static func object(
    _ value: Any?,
    path: String,
    required: Set<String>,
    optional: Set<String> = []
  ) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
      throw BuildProxyManifestError.invalidShape("\(path) must be an object")
    }
    let keys = Set(object.keys)
    let missing = required.subtracting(keys)
    guard missing.isEmpty else {
      throw BuildProxyManifestError.invalidShape(
        "\(path) is missing keys: \(missing.sorted().joined(separator: ", "))"
      )
    }
    let unknown = keys.subtracting(required.union(optional))
    guard unknown.isEmpty else {
      throw BuildProxyManifestError.invalidShape(
        "\(path) has unknown keys: \(unknown.sorted().joined(separator: ", "))"
      )
    }
    return object
  }
}

enum BuildProxySecurity {
  static func validateRelativePath(_ value: String, field: String) throws {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !value.isEmpty,
      !value.hasPrefix("/"),
      !value.hasPrefix("~"),
      !hasControlCharacters(value),
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
      throw BuildProxyManifestError.invalidContract("\(field) is not a safe relative path")
    }
  }

  static func isEnvironmentKey(_ value: String) -> Bool {
    guard let first = value.utf8.first, first == 0x5F || isASCIILetter(first) else {
      return false
    }
    return value.utf8.dropFirst().allSatisfy {
      $0 == 0x5F || isASCIILetter($0) || (0x30...0x39).contains($0)
    }
  }

  private static func isASCIILetter(_ value: UInt8) -> Bool {
    (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
  }

  static func isSensitiveEnvironmentKey(_ value: String) -> Bool {
    let normalized = value.uppercased().replacingOccurrences(of: "-", with: "_")
    return [
      "TOKEN", "PASSWORD", "SECRET", "CREDENTIAL", "API_KEY", "AUTHORIZATION", "COOKIE",
      "HEADER",
    ].contains(where: normalized.contains)
  }

  static func containsSensitiveEnvironmentValue(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    let markers = [
      "authorization:", "bearer ", "basic ", "cookie:", "token=", "password=", "secret=",
      "credential=", "api_key=", "api-key=", "remote_header=", "remote-header=", "bes_header=",
      "remote_cache_header=",
    ]
    if markers.contains(where: lowercased.contains) {
      return true
    }
    if let components = URLComponents(string: value),
      components.scheme != nil,
      components.user != nil || components.password != nil
    {
      return true
    }
    return false
  }

  static func hasControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      scalar.value < 0x20 || scalar.value == 0x7F
    }
  }

  static func relativeDescendantPath(child: URL, parent: URL) -> String? {
    let childPath = child.standardizedFileURL.path
    let parentPath = parent.standardizedFileURL.path
    let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
    guard childPath.hasPrefix(prefix) else { return nil }
    return String(childPath.dropFirst(prefix.count))
  }
}
