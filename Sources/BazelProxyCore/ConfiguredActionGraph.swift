import Darwin
import Foundation

struct BazelActionReconciliationKey: Hashable, Sendable {
  let label: String
  let primaryOutput: String

  init(label: String, primaryOutput: String) {
    if label.hasPrefix("@@//") {
      self.label = String(label.dropFirst(2))
    } else if label.hasPrefix("@//") {
      self.label = String(label.dropFirst())
    } else {
      self.label = label
    }
    self.primaryOutput = primaryOutput
  }
}

public struct BazelConfiguredAction: Equatable, Hashable, Sendable {
  public let commandLineDisplayString: String?
  public let configuration: String
  public let identity: String
  public let label: String
  public let mnemonic: String
  public let primaryOutput: String

  public init(
    commandLineDisplayString: String? = nil,
    configuration: String,
    label: String,
    mnemonic: String,
    primaryOutput: String
  ) {
    self.commandLineDisplayString = commandLineDisplayString
    self.configuration = configuration
    self.label = label
    self.mnemonic = mnemonic
    self.primaryOutput = primaryOutput
    self.identity = [label, primaryOutput, configuration].joined(separator: "|")
  }

  var reconciliationKey: BazelActionReconciliationKey {
    BazelActionReconciliationKey(label: label, primaryOutput: primaryOutput)
  }
}

extension BEPActionCompleted {
  var reconciliationKey: BazelActionReconciliationKey {
    BazelActionReconciliationKey(label: label, primaryOutput: primaryOutput)
  }
}

public enum BazelActionDisposition: Equatable, Sendable {
  case cacheHit(BazelCacheKind)
  case completed(succeeded: Bool)
  case executed(succeeded: Bool, runner: String?)
  case upToDate
}

public struct BazelPresentedAction: Equatable, Sendable {
  public let commandLineDisplayString: String?
  public let configuration: String
  public let disposition: BazelActionDisposition
  public let identity: String
  public let label: String
  public let mnemonic: String?
  public let primaryOutput: String
  public let timing: BazelExecutionTiming?

  public init(
    completed action: BEPActionCompleted,
    configured: BazelConfiguredAction? = nil,
    executionRecord: BazelExecutionRecord? = nil
  ) {
    self.commandLineDisplayString =
      executionRecord?.commandLineDisplayString
      ?? action.commandLineDisplayString
      ?? configured?.commandLineDisplayString
    self.configuration = action.configuration
    if action.succeeded == false {
      self.disposition = .completed(succeeded: false)
    } else if let executionRecord, executionRecord.cacheHit {
      self.disposition = .cacheHit(executionRecord.cacheKind)
    } else if let executionRecord {
      self.disposition = .executed(
        succeeded: action.succeeded == true,
        runner: executionRecord.runner
      )
    } else {
      self.disposition = .completed(succeeded: action.succeeded == true)
    }
    self.identity = action.identity
    self.label = action.label
    self.mnemonic = configured?.mnemonic ?? action.mnemonic ?? executionRecord?.mnemonic
    self.primaryOutput = action.primaryOutput
    self.timing = executionRecord?.timing ?? action.timing
  }

  public init(upToDate action: BazelConfiguredAction) {
    self.commandLineDisplayString = action.commandLineDisplayString
    self.configuration = action.configuration
    self.disposition = .upToDate
    self.identity = action.identity
    self.label = action.label
    self.mnemonic = action.mnemonic
    self.primaryOutput = action.primaryOutput
    self.timing = nil
  }

  public init(configured action: BazelConfiguredAction, executionRecord: BazelExecutionRecord) {
    self.commandLineDisplayString =
      executionRecord.commandLineDisplayString ?? action.commandLineDisplayString
    self.configuration = action.configuration
    if executionRecord.cacheHit {
      self.disposition = .cacheHit(executionRecord.cacheKind)
    } else {
      self.disposition = .executed(
        succeeded: executionRecord.exitCode.map { $0 == 0 } ?? true,
        runner: executionRecord.runner
      )
    }
    self.identity = action.identity
    self.label = action.label
    self.mnemonic = action.mnemonic
    self.primaryOutput = action.primaryOutput
    self.timing = executionRecord.timing
  }

  public var taskTitle: String {
    let outputName = URL(fileURLWithPath: primaryOutput).lastPathComponent
    let labelName = label.split(separator: ":", omittingEmptySubsequences: false).last.map(
      String.init)
    switch mnemonic {
    case "SwiftCompile":
      let module =
        outputName.hasSuffix(".swiftmodule")
        ? String(outputName.dropLast(".swiftmodule".count))
        : labelName ?? outputName
      return "Compile Swift module \(module)"
    case "CppArchive":
      var archive = outputName.hasSuffix(".a") ? String(outputName.dropLast(2)) : outputName
      if archive.hasPrefix("lib") { archive.removeFirst(3) }
      return "Archive \(archive.isEmpty ? (labelName ?? "Bazel target") : archive)"
    case "ObjcLink":
      return "Link \(outputName.isEmpty ? (labelName ?? "Bazel target") : outputName)"
    case "BundleTreeApp":
      return "Assemble \(outputName.isEmpty ? (labelName ?? "app") : outputName)"
    case "Symlink":
      return "Create symlink \(outputName.isEmpty ? (labelName ?? "output") : outputName)"
    case "BazelWorkspaceStatusAction":
      return "Update Bazel workspace status"
    case "FileWrite":
      return "Write \(outputName.isEmpty ? (labelName ?? "generated file") : outputName)"
    case "CompileRootInfoPlist":
      return "Process Info.plist"
    case "ProcessEntitlementsFiles":
      return "Process entitlements"
    case "ProcessDEREntitlements":
      return "Process DER entitlements"
    case "ProcessSimulatorEntitlementsFile":
      return "Process simulator entitlements"
    case "Action":
      return "Generate \(outputName.isEmpty ? (labelName ?? "Bazel output") : outputName)"
    case .some(let mnemonic):
      return outputName.isEmpty ? mnemonic : "\(mnemonic) \(outputName)"
    case nil:
      return outputName.isEmpty ? "Bazel action" : "Bazel action \(outputName)"
    }
  }
}

public struct BazelActionPresentationSummary: Equatable, Sendable {
  public let cacheHits: Int
  public let completedStatusUnavailable: Int
  public let executed: Int
  public let presented: Int
  public let upToDate: Int

  public init(
    cacheHits: Int = 0,
    completedStatusUnavailable: Int = 0,
    executed: Int,
    presented: Int,
    upToDate: Int
  ) {
    self.cacheHits = cacheHits
    self.completedStatusUnavailable = completedStatusUnavailable
    self.executed = executed
    self.presented = presented
    self.upToDate = upToDate
  }
}

public struct ConfiguredActionGraphValidation: Equatable, Sendable {
  public let actions: [BazelConfiguredAction]
  public let fileBytes: Int
}

public struct ConfiguredActionGraphLimits: Equatable, Sendable {
  public let command: BazelCommandDisplayLimits
  public let maximumFileBytes: Int

  public init(
    maximumFileBytes: Int = 256 * 1024 * 1024,
    command: BazelCommandDisplayLimits = BazelCommandDisplayLimits()
  ) {
    self.maximumFileBytes = maximumFileBytes
    self.command = command
  }
}

public enum ConfiguredActionGraphError: LocalizedError, Equatable, Sendable {
  case actionCycle
  case depSetCycle
  case duplicateActionIdentity(String)
  case duplicateOutput(Int)
  case fileLimitExceeded(Int)
  case invalidLimits
  case invalidShape
  case missingProduct(String)
  case readFailed(errno: Int32)
  case unsafeFile(String)

  public var errorDescription: String? {
    switch self {
    case .actionCycle:
      return "The configured action graph contains an action cycle."
    case .depSetCycle:
      return "The configured action graph contains a dependency-set cycle."
    case .duplicateActionIdentity(let identity):
      return "The configured action graph repeats action identity \(identity)."
    case .duplicateOutput(let identifier):
      return "The configured action graph has multiple producers for artifact \(identifier)."
    case .fileLimitExceeded(let limit):
      return "The configured action graph exceeds the \(limit)-byte file limit."
    case .invalidLimits:
      return "The configured action graph file limit must be positive."
    case .invalidShape:
      return "The configured action graph is malformed or internally inconsistent."
    case .missingProduct(let path):
      return "The configured action graph does not contain requested product \(path)."
    case .readFailed(let errorNumber):
      return "The configured action graph read failed with errno \(errorNumber)."
    case .unsafeFile(let path):
      return "The configured action graph is missing, linked, non-regular, or oversized: \(path)"
    }
  }
}

/// Loads only the structural allowlist and command arguments needed to present the selected
/// product's configured action closure. Environment variables, execution properties, inputs, and
/// file contents in the raw aquery JSON are intentionally not represented by the decoding model.
public enum ConfiguredActionGraphValidator {
  public static func validate(
    fileAt url: URL,
    productPaths: Set<String>,
    configurations: Set<String>,
    limits: ConfiguredActionGraphLimits = ConfiguredActionGraphLimits()
  ) throws -> ConfiguredActionGraphValidation {
    guard limits.maximumFileBytes > 0,
      limits.command.maximumArgumentBytes > 0,
      limits.command.maximumArgumentCount > 0,
      limits.command.maximumDisplayBytes > 0
    else {
      throw ConfiguredActionGraphError.invalidLimits
    }
    let data = try read(url, maximumBytes: limits.maximumFileBytes)
    let container: ActionGraphContainer
    do {
      container = try JSONDecoder().decode(ActionGraphContainer.self, from: data)
    } catch {
      throw ConfiguredActionGraphError.invalidShape
    }
    let resolver = try ActionGraphResolver(container: container, commandLimits: limits.command)
    let actions = try resolver.actions(
      producing: productPaths,
      configurations: configurations
    )
    return ConfiguredActionGraphValidation(actions: actions, fileBytes: data.count)
  }

  private static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw ConfiguredActionGraphError.unsafeFile(url.absoluteString)
    }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw ConfiguredActionGraphError.unsafeFile(url.path) }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0
    else {
      throw ConfiguredActionGraphError.unsafeFile(url.path)
    }
    guard status.st_size <= maximumBytes else {
      throw ConfiguredActionGraphError.fileLimitExceeded(maximumBytes)
    }

    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw ConfiguredActionGraphError.readFailed(errno: errno)
      }
      guard data.count <= maximumBytes - count else {
        throw ConfiguredActionGraphError.fileLimitExceeded(maximumBytes)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }
}

private final class ActionGraphResolver {
  private enum VisitState {
    case visiting
    case visited
  }

  private let actions: [ActionGraphAction]
  private let artifacts: [Int: ActionGraphArtifact]
  private let configurations: [Int: String]
  private let depSets: [Int: ActionGraphDepSet]
  private let pathFragments: [Int: ActionGraphPathFragment]
  private let producers: [Int: Int]
  private let targets: [Int: String]
  private let commandLimits: BazelCommandDisplayLimits
  private var depSetCache = [Int: [Int]]()
  private var depSetVisits = [Int: VisitState]()

  init(container: ActionGraphContainer, commandLimits: BazelCommandDisplayLimits) throws {
    self.actions = container.actions
    self.artifacts = try Self.uniqueMap(container.artifacts, identifier: \.id)
    self.configurations = try Self.uniqueMap(container.configurations, identifier: \.id)
      .mapValues(\.mnemonic)
    self.depSets = try Self.uniqueMap(container.depSets, identifier: \.id)
    self.pathFragments = try Self.uniqueMap(container.pathFragments, identifier: \.id)
    self.targets = try Self.uniqueMap(container.targets, identifier: \.id).mapValues(\.label)
    self.commandLimits = commandLimits

    var producers = [Int: Int]()
    for (actionIndex, action) in container.actions.enumerated() {
      for output in action.outputIDs {
        guard producers.updateValue(actionIndex, forKey: output) == nil else {
          throw ConfiguredActionGraphError.duplicateOutput(output)
        }
      }
    }
    self.producers = producers
  }

  private static func uniqueMap<Element>(
    _ elements: [Element],
    identifier: KeyPath<Element, Int>
  ) throws -> [Int: Element] {
    var result = [Int: Element]()
    for element in elements {
      guard result.updateValue(element, forKey: element[keyPath: identifier]) == nil else {
        throw ConfiguredActionGraphError.invalidShape
      }
    }
    return result
  }

  func actions(
    producing requestedProductPaths: Set<String>,
    configurations requestedConfigurations: Set<String>
  ) throws -> [BazelConfiguredAction] {
    var artifactPaths = [Int: String]()
    for identifier in artifacts.keys.sorted() {
      artifactPaths[identifier] = try artifactPath(identifier)
    }
    var roots = [Int]()
    for productPath in requestedProductPaths.sorted() {
      guard let artifact = artifactPaths.first(where: { $0.value == productPath })?.key else {
        throw ConfiguredActionGraphError.missingProduct(productPath)
      }
      roots.append(artifact)
    }

    var actionVisits = [Int: VisitState]()
    var orderedActions = [Int]()
    func visitArtifact(_ artifact: Int) throws {
      guard let action = producers[artifact] else { return }
      try visitAction(action)
    }
    func visitAction(_ index: Int) throws {
      if actionVisits[index] == .visiting { throw ConfiguredActionGraphError.actionCycle }
      if actionVisits[index] == .visited { return }
      actionVisits[index] = .visiting
      for depSet in actions[index].inputDepSetIDs {
        for artifact in try depSetArtifacts(depSet) {
          try visitArtifact(artifact)
        }
      }
      actionVisits[index] = .visited
      orderedActions.append(index)
    }
    for root in roots {
      try visitArtifact(root)
    }

    var result = [BazelConfiguredAction]()
    var identities = Set<String>()
    for index in orderedActions {
      let action = actions[index]
      guard let configuration = configurations[action.configurationID],
        requestedConfigurations.contains(configuration)
      else { continue }
      guard let label = targets[action.targetID],
        let primaryOutputID = action.primaryOutputID,
        let primaryOutput = artifactPaths[primaryOutputID],
        !action.mnemonic.isEmpty,
        !BuildProxySecurity.hasControlCharacters(label),
        !BuildProxySecurity.hasControlCharacters(action.mnemonic),
        !BuildProxySecurity.hasControlCharacters(primaryOutput)
      else {
        throw ConfiguredActionGraphError.invalidShape
      }
      let commandLineDisplayString = BazelCommandDisplay.sanitize(
        action.arguments,
        limits: commandLimits
      )
      let configured = BazelConfiguredAction(
        commandLineDisplayString: commandLineDisplayString,
        configuration: configuration,
        label: label,
        mnemonic: action.mnemonic,
        primaryOutput: primaryOutput
      )
      guard identities.insert(configured.identity).inserted else {
        throw ConfiguredActionGraphError.duplicateActionIdentity(configured.identity)
      }
      result.append(configured)
    }
    return result
  }

  private func artifactPath(_ identifier: Int) throws -> String {
    guard let artifact = artifacts[identifier] else {
      throw ConfiguredActionGraphError.invalidShape
    }
    var labels = [String]()
    var visited = Set<Int>()
    var current: Int? = artifact.pathFragmentID
    while let identifier = current {
      guard visited.insert(identifier).inserted,
        let fragment = pathFragments[identifier]
      else {
        throw ConfiguredActionGraphError.invalidShape
      }
      labels.append(fragment.label)
      current = fragment.parentID
    }
    return labels.reversed().joined(separator: "/")
  }

  private func depSetArtifacts(_ identifier: Int) throws -> [Int] {
    if let cached = depSetCache[identifier] { return cached }
    if depSetVisits[identifier] == .visiting { throw ConfiguredActionGraphError.depSetCycle }
    guard let depSet = depSets[identifier] else {
      throw ConfiguredActionGraphError.invalidShape
    }
    depSetVisits[identifier] = .visiting
    var result = [Int]()
    var seen = Set<Int>()
    for artifact in depSet.directArtifactIDs where seen.insert(artifact).inserted {
      result.append(artifact)
    }
    for transitive in depSet.transitiveDepSetIDs {
      for artifact in try depSetArtifacts(transitive) where seen.insert(artifact).inserted {
        result.append(artifact)
      }
    }
    depSetVisits[identifier] = .visited
    depSetCache[identifier] = result
    return result
  }
}

private struct ActionGraphContainer: Decodable {
  let actions: [ActionGraphAction]
  let artifacts: [ActionGraphArtifact]
  let configurations: [ActionGraphConfiguration]
  let depSets: [ActionGraphDepSet]
  let pathFragments: [ActionGraphPathFragment]
  let targets: [ActionGraphTarget]

  private enum CodingKeys: String, CodingKey {
    case actions
    case artifacts
    case configurations = "configuration"
    case depSets = "depSetOfFiles"
    case pathFragments
    case targets
  }
}

private struct ActionGraphAction: Decodable {
  let arguments: [String]
  let configurationID: Int
  let inputDepSetIDs: [Int]
  let mnemonic: String
  let outputIDs: [Int]
  let primaryOutputID: Int?
  let targetID: Int

  private enum CodingKeys: String, CodingKey {
    case arguments
    case configurationID = "configurationId"
    case inputDepSetIDs = "inputDepSetIds"
    case mnemonic
    case outputIDs = "outputIds"
    case primaryOutputID = "primaryOutputId"
    case targetID = "targetId"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
    configurationID = try values.decodeIfPresent(Int.self, forKey: .configurationID) ?? -1
    inputDepSetIDs = try values.decodeIfPresent([Int].self, forKey: .inputDepSetIDs) ?? []
    mnemonic = try values.decodeIfPresent(String.self, forKey: .mnemonic) ?? ""
    outputIDs = try values.decodeIfPresent([Int].self, forKey: .outputIDs) ?? []
    primaryOutputID = try values.decodeIfPresent(Int.self, forKey: .primaryOutputID)
    targetID = try values.decodeIfPresent(Int.self, forKey: .targetID) ?? -1
  }
}

private struct ActionGraphArtifact: Decodable {
  let id: Int
  let pathFragmentID: Int

  private enum CodingKeys: String, CodingKey {
    case id
    case pathFragmentID = "pathFragmentId"
  }
}

private struct ActionGraphConfiguration: Decodable {
  let id: Int
  let mnemonic: String
}

private struct ActionGraphDepSet: Decodable {
  let directArtifactIDs: [Int]
  let id: Int
  let transitiveDepSetIDs: [Int]

  private enum CodingKeys: String, CodingKey {
    case directArtifactIDs = "directArtifactIds"
    case id
    case transitiveDepSetIDs = "transitiveDepSetIds"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    directArtifactIDs = try values.decodeIfPresent([Int].self, forKey: .directArtifactIDs) ?? []
    id = try values.decode(Int.self, forKey: .id)
    transitiveDepSetIDs =
      try values.decodeIfPresent([Int].self, forKey: .transitiveDepSetIDs) ?? []
  }
}

private struct ActionGraphPathFragment: Decodable {
  let id: Int
  let label: String
  let parentID: Int?

  private enum CodingKeys: String, CodingKey {
    case id
    case label
    case parentID = "parentId"
  }
}

private struct ActionGraphTarget: Decodable {
  let id: Int
  let label: String
}
