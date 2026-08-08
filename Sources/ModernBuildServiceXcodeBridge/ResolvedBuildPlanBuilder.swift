import BazelProxyCore
import Foundation
import SWBProtocol

public enum ResolvedBuildPlanSettingRole: String, CaseIterable, Sendable {
  case bazelLabel = "BAZEL_LABEL"
  case bazelTargetID = "BAZEL_TARGET_ID"
  case bazelIntegrationDirectory = "BAZEL_INTEGRATION_DIR"
  case bazelOutputDirectory = "BAZEL_OUT"
  case bazelWorkspaceRoot = "BAZEL_WORKSPACE_ROOT"
  case sourceRoot = "SRCROOT"
  case targetBuildDirectory = "TARGET_BUILD_DIR"
  case fullProductName = "FULL_PRODUCT_NAME"
  case targetName = "TARGET_NAME"
  case projectName = "PROJECT_NAME"
  case projectFilePath = "PROJECT_FILE_PATH"
  case previewsEnabled = "ENABLE_PREVIEWS"

  public static let orderedKeys = allCases.map(\.rawValue)
}

public struct ExportedSettingValue: Equatable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

/// One target's exported shell-task settings projected onto the manifest-owned allowlist.
///
/// The complete exported settings dictionary is accepted only at this initializer boundary. Values
/// not named by a fixed plan role or `manifest.invocation.environmentKeys` are discarded before the
/// snapshot can cross into operation planning.
public struct PerTargetExportedSettingsSnapshot: Equatable, Sendable {
  public let manifestFileIdentity: BuildProxyManifestFileIdentity
  public let targetGUID: String
  public let values: [ExportedSettingValue]

  public init(
    targetGUID: String,
    exportedValues: [String: String],
    verifiedManifest: VerifiedBuildProxyManifest
  ) {
    let allowlist = Set(ResolvedBuildPlanSettingRole.orderedKeys)
      .union(verifiedManifest.manifest.invocation.environmentKeys)
    manifestFileIdentity = verifiedManifest.fileIdentity
    self.targetGUID = targetGUID
    values = allowlist.sorted().compactMap { key in
      exportedValues[key].map { ExportedSettingValue(key: key, value: $0) }
    }
  }

  public func value(for role: ResolvedBuildPlanSettingRole) -> String? {
    value(forKey: role.rawValue)
  }

  public func value(forKey key: String) -> String? {
    values.first { $0.key == key }?.value
  }
}

public enum ResolvedBuildPlanRejection: LocalizedError, Equatable, Sendable {
  case duplicateConfiguredTarget(String)
  case duplicateSettingsSnapshot(String)
  case effectiveParametersDisagree(String)
  case emptyOperationID
  case invalidManifestIdentity
  case invalidPath(targetGUID: String, role: String)
  case invalidSetting(targetGUID: String, key: String)
  case manifestDirectoryMismatch
  case manifestIdentityMismatch(targetGUID: String)
  case missingSettingsSnapshot(String)
  case operationWideSettingDisagreement(String)
  case productBasenameMismatch(targetGUID: String)
  case projectContainerMismatch
  case routing(TargetRoutingError)
  case targetIdentityMismatch(targetGUID: String)
  case unexpectedSettingsSnapshot(String)
  case unsafeOperationID

  public var errorDescription: String? {
    switch self {
    case .duplicateConfiguredTarget(let guid):
      return "The build request contains target GUID \(guid) more than once."
    case .duplicateSettingsSnapshot(let guid):
      return "More than one exported-settings snapshot was supplied for target GUID \(guid)."
    case .effectiveParametersDisagree(let field):
      return "Configured targets disagree on effective build parameter \(field)."
    case .emptyOperationID:
      return "The resolved build-plan operation ID is empty."
    case .invalidManifestIdentity:
      return "The verified build proxy manifest identity is malformed."
    case .invalidPath(let targetGUID, let role):
      return "Target \(targetGUID) has an invalid absolute path for \(role)."
    case .invalidSetting(let targetGUID, let key):
      return "Target \(targetGUID) has a missing, empty, or unsafe value for \(key)."
    case .manifestDirectoryMismatch:
      return
        "The evaluated rules_xcodeproj integration directory does not contain the verified manifest."
    case .manifestIdentityMismatch(let targetGUID):
      return "Target \(targetGUID) settings were not captured for the verified manifest snapshot."
    case .missingSettingsSnapshot(let guid):
      return "No exported-settings snapshot was supplied for target GUID \(guid)."
    case .operationWideSettingDisagreement(let key):
      return "Configured targets disagree on operation-wide setting \(key)."
    case .productBasenameMismatch(let targetGUID):
      return "Target \(targetGUID) has a product basename that disagrees with the manifest."
    case .projectContainerMismatch:
      return
        "The build request, evaluated project, and verified manifest do not identify one project container."
    case .routing(let error):
      return error.localizedDescription
    case .targetIdentityMismatch(let targetGUID):
      return "Target \(targetGUID) evaluated identity does not match its resolved manifest target."
    case .unexpectedSettingsSnapshot(let guid):
      return "An exported-settings snapshot was supplied for unexpected target GUID \(guid)."
    case .unsafeOperationID:
      return "The resolved build-plan operation ID is unsafe."
    }
  }
}

public enum ResolvedBuildPlanDecision: Equatable, Sendable {
  case forwardNative(NativeForwardReason)
  case intercept(ResolvedBuildPlan)
  case reject(ResolvedBuildPlanRejection)
}

public enum ResolvedBuildPlanBuilder {
  public static func resolve(
    operationID: String,
    request: CreateBuildRequest,
    manifestURL: URL,
    verifiedManifest: VerifiedBuildProxyManifest,
    settingsSnapshots: [PerTargetExportedSettingsSnapshot]
  ) -> ResolvedBuildPlanDecision {
    do {
      return try resolveOrThrow(
        operationID: operationID,
        request: request,
        manifestURL: manifestURL,
        verifiedManifest: verifiedManifest,
        settingsSnapshots: settingsSnapshots
      )
    } catch let rejection as ResolvedBuildPlanRejection {
      return .reject(rejection)
    } catch {
      preconditionFailure("ResolvedBuildPlanBuilder threw an untyped error: \(error)")
    }
  }

  private struct EffectiveParameters: Equatable {
    let action: String
    let architecture: String?
    let configuration: String
    let platform: String?
  }

  private struct TargetInput {
    let configuredTarget: ConfiguredTargetMessagePayload
    let parameters: EffectiveParameters
    let snapshot: PerTargetExportedSettingsSnapshot
  }

  private static let targetScopedKeys: Set<String> = [
    ResolvedBuildPlanSettingRole.bazelLabel.rawValue,
    ResolvedBuildPlanSettingRole.bazelTargetID.rawValue,
    ResolvedBuildPlanSettingRole.fullProductName.rawValue,
    ResolvedBuildPlanSettingRole.targetBuildDirectory.rawValue,
    ResolvedBuildPlanSettingRole.targetName.rawValue,
  ]

  private static func resolveOrThrow(
    operationID: String,
    request: CreateBuildRequest,
    manifestURL: URL,
    verifiedManifest: VerifiedBuildProxyManifest,
    settingsSnapshots: [PerTargetExportedSettingsSnapshot]
  ) throws -> ResolvedBuildPlanDecision {
    try validateOperationID(operationID)
    try validateManifestIdentity(verifiedManifest.fileIdentity)

    if request.onlyCreateBuildDescription {
      return .forwardNative(.buildDescriptionOnly)
    }

    let configuredTargets = request.request.configuredTargets
    guard !configuredTargets.isEmpty else {
      return .forwardNative(.noRequestedTargets)
    }

    let snapshotsByGUID = try indexSnapshots(
      settingsSnapshots,
      configuredTargets: configuredTargets,
      manifestIdentity: verifiedManifest.fileIdentity
    )
    let targetInputs = try configuredTargets.map { configuredTarget in
      guard let snapshot = snapshotsByGUID[configuredTarget.guid] else {
        throw ResolvedBuildPlanRejection.missingSettingsSnapshot(configuredTarget.guid)
      }
      return TargetInput(
        configuredTarget: configuredTarget,
        parameters: try effectiveParameters(
          configuredTarget.parameters ?? request.request.parameters
        ),
        snapshot: snapshot
      )
    }
    try validateEffectiveParameterAgreement(targetInputs)
    try validateOperationWideSettingAgreement(
      targetInputs,
      manifest: verifiedManifest.manifest
    )

    let normalizedCommand = normalizeCommand(
      request.request.buildCommand,
      parameters: targetInputs[0].parameters
    )
    guard case .supported(let action, let mode, let schemeAction) = normalizedCommand else {
      guard case .unsupported(let value) = normalizedCommand else {
        preconditionFailure("Unknown normalized command result")
      }
      return .forwardNative(.unsupportedAction(value))
    }

    let projectResolution = try projectContainerResolution(
      request: request,
      targetInputs: targetInputs,
      manifestURL: manifestURL,
      manifest: verifiedManifest.manifest
    )
    guard case .proxyOwned(let projectURL) = projectResolution else {
      return .forwardNative(.unrelatedProject)
    }
    let workspaceURL = try commonAbsoluteURL(
      targetInputs,
      preferredRole: .bazelWorkspaceRoot,
      fallbackRole: .sourceRoot
    )
    let requestedTargets = targetInputs.map { targetInput in
      RequestedTarget(
        bazelLabel: nonempty(targetInput.snapshot.value(for: .bazelLabel)),
        targetID: nonempty(targetInput.snapshot.value(for: .bazelTargetID)),
        targetName: nonempty(targetInput.snapshot.value(for: .targetName)) ?? "",
        xcodeTargetGUID: targetInput.configuredTarget.guid
      )
    }
    let intent = BuildIntent(
      action: action,
      architecture: targetInputs[0].parameters.architecture,
      configuration: targetInputs[0].parameters.configuration,
      mode: mode,
      platform: targetInputs[0].parameters.platform,
      projectContainerURL: projectURL,
      requestedTargets: requestedTargets,
      schemeAction: schemeAction,
      workspaceURL: workspaceURL
    )

    switch TargetResolver.resolve(intent: intent, manifest: verifiedManifest.manifest) {
    case .forwardNative(let reason):
      return .forwardNative(reason)
    case .reject(let error):
      return .reject(.routing(error))
    case .intercept(let mappings):
      let plan = try makePlan(
        operationID: operationID,
        intent: intent,
        request: request,
        manifestURL: manifestURL,
        verifiedManifest: verifiedManifest,
        targetInputs: targetInputs,
        mappings: mappings
      )
      return .intercept(plan)
    }
  }

  private enum NormalizedCommand {
    case supported(BuildIntentAction, BuildIntentMode, schemeAction: String)
    case unsupported(String)
  }

  private static func normalizeCommand(
    _ command: BuildCommandMessagePayload,
    parameters: EffectiveParameters
  ) -> NormalizedCommand {
    switch command {
    case .build:
      if parameters.action == "indexbuild" {
        return .supported(.indexBuild, .standard, schemeAction: "build")
      }
      return .supported(.build, .standard, schemeAction: parameters.action)
    case .cleanBuildFolder:
      return .supported(.clean, .standard, schemeAction: "build")
    case .cleanBuildFolderAndCaches:
      return .supported(.clean, .standard, schemeAction: "build")
    case .preview:
      return .supported(.build, .preview, schemeAction: parameters.action)
    case .cleanCaches:
      return .unsupported("cleanCaches")
    case .generateAssemblyCode:
      return .unsupported("generateAssemblyCode")
    case .generatePreprocessedFile:
      return .unsupported("generatePreprocessedFile")
    case .migrate:
      return .unsupported("migrate")
    case .prepareForIndexing:
      return .unsupported("prepareForIndexing")
    case .singleFileBuild:
      return .unsupported("singleFileBuild")
    }
  }

  private static func makePlan(
    operationID: String,
    intent: BuildIntent,
    request: CreateBuildRequest,
    manifestURL: URL,
    verifiedManifest: VerifiedBuildProxyManifest,
    targetInputs: [TargetInput],
    mappings: [BuildProxyManifest.Target]
  ) throws -> ResolvedBuildPlan {
    let inputByGUID = Dictionary(
      uniqueKeysWithValues: targetInputs.map {
        ($0.configuredTarget.guid, $0)
      })
    var resolvedTargets = [ResolvedTargetPlan]()
    for mapping in mappings {
      guard let targetInput = inputByGUID[mapping.xcodeTargetGUID] else {
        throw ResolvedBuildPlanRejection.targetIdentityMismatch(
          targetGUID: mapping.xcodeTargetGUID
        )
      }
      try validateRequiredPlanRoles(targetInput.snapshot)
      try validateTargetIdentity(targetInput, mapping: mapping)
      let productPaths = try resolveProductPaths(targetInput, mapping: mapping)
      resolvedTargets.append(
        ResolvedTargetPlan(mapping: mapping, productPaths: productPaths)
      )
    }

    try validatePreviewAgreement(intent: intent, targetInputs: targetInputs)
    try validateIntegrationDirectory(
      targetInputs: targetInputs,
      manifestURL: manifestURL
    )
    try validateAdapterAction(intent: intent, targetInputs: targetInputs)

    let environment = try makeAdapterEnvironment(
      targetInputs: targetInputs,
      manifest: verifiedManifest.manifest
    )
    let adapterRequest: AdapterRequest
    if intent.action == .clean {
      adapterRequest = AdapterRequest(labels: [], outputGroups: [], targetIDs: [])
    } else {
      let outputGroups: [String]
      switch (intent.action, intent.mode) {
      case (.indexBuild, _):
        outputGroups = mappings.flatMap(\.indexOutputGroups)
      case (.build, .preview):
        outputGroups = mappings.flatMap(\.previewOutputGroups)
      default:
        outputGroups = mappings.map(\.outputGroup)
      }
      adapterRequest = AdapterRequest(
        labels: mappings.map(\.bazelLabel),
        outputGroups: outputGroups,
        targetIDs: mappings.map(\.targetID)
      )
    }

    return ResolvedBuildPlan(
      adapterRequest: adapterRequest,
      evaluatedEnvironment: environment,
      intent: intent,
      manifest: verifiedManifest.manifest,
      manifestURL: manifestURL.standardizedFileURL,
      operationID: operationID,
      targets: resolvedTargets
    )
  }

  private static func indexSnapshots(
    _ snapshots: [PerTargetExportedSettingsSnapshot],
    configuredTargets: [ConfiguredTargetMessagePayload],
    manifestIdentity: BuildProxyManifestFileIdentity
  ) throws -> [String: PerTargetExportedSettingsSnapshot] {
    var configuredGUIDs = Set<String>()
    for target in configuredTargets where !configuredGUIDs.insert(target.guid).inserted {
      throw ResolvedBuildPlanRejection.duplicateConfiguredTarget(target.guid)
    }

    var result = [String: PerTargetExportedSettingsSnapshot]()
    for snapshot in snapshots {
      guard configuredGUIDs.contains(snapshot.targetGUID) else {
        throw ResolvedBuildPlanRejection.unexpectedSettingsSnapshot(snapshot.targetGUID)
      }
      guard snapshot.manifestFileIdentity == manifestIdentity else {
        throw ResolvedBuildPlanRejection.manifestIdentityMismatch(
          targetGUID: snapshot.targetGUID
        )
      }
      guard result.updateValue(snapshot, forKey: snapshot.targetGUID) == nil else {
        throw ResolvedBuildPlanRejection.duplicateSettingsSnapshot(snapshot.targetGUID)
      }
    }
    return result
  }

  private static func effectiveParameters(
    _ parameters: BuildParametersMessagePayload
  ) throws -> EffectiveParameters {
    guard !parameters.action.isEmpty,
      !parameters.action.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let configuration = nonempty(parameters.configuration),
      !configuration.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ResolvedBuildPlanRejection.effectiveParametersDisagree("action/configuration")
    }
    let platform: String?
    switch parameters.activeRunDestination?.buildTarget {
    case .toolchainSDK(let value, _, _):
      platform = nonempty(value)
    case .swiftSDK, .inMemorySwiftSDK, nil:
      platform = nil
    }
    let architecture =
      normalizedArchitecture(parameters.activeArchitecture)
      ?? normalizedArchitecture(parameters.activeRunDestination?.targetArchitecture)
    return EffectiveParameters(
      action: parameters.action,
      architecture: architecture,
      configuration: configuration,
      platform: platform
    )
  }

  private static func validateEffectiveParameterAgreement(
    _ targetInputs: [TargetInput]
  ) throws {
    guard let first = targetInputs.first else { return }
    for input in targetInputs.dropFirst() {
      guard input.parameters.action == first.parameters.action else {
        throw ResolvedBuildPlanRejection.effectiveParametersDisagree("action")
      }
      guard input.parameters.configuration == first.parameters.configuration else {
        throw ResolvedBuildPlanRejection.effectiveParametersDisagree("configuration")
      }
      guard input.parameters.platform == first.parameters.platform else {
        throw ResolvedBuildPlanRejection.effectiveParametersDisagree("platform")
      }
      guard input.parameters.architecture == first.parameters.architecture else {
        throw ResolvedBuildPlanRejection.effectiveParametersDisagree("architecture")
      }
    }
  }

  private static func validateOperationWideSettingAgreement(
    _ targetInputs: [TargetInput],
    manifest: BuildProxyManifest
  ) throws {
    guard let first = targetInputs.first else { return }
    let operationWideKeys = Set(ResolvedBuildPlanSettingRole.orderedKeys)
      .subtracting(targetScopedKeys)
      .union(manifest.invocation.environmentKeys)
    for key in operationWideKeys.sorted() {
      let expected = first.snapshot.value(forKey: key) ?? ""
      if targetInputs.dropFirst().contains(where: {
        ($0.snapshot.value(forKey: key) ?? "") != expected
      }) {
        throw ResolvedBuildPlanRejection.operationWideSettingDisagreement(key)
      }
    }
  }

  private enum ProjectContainerResolution {
    case proxyOwned(URL)
    case unrelated
  }

  private static func projectContainerResolution(
    request: CreateBuildRequest,
    targetInputs: [TargetInput],
    manifestURL: URL,
    manifest: BuildProxyManifest
  ) throws -> ProjectContainerResolution {
    guard let first = targetInputs.first else {
      throw ResolvedBuildPlanRejection.projectContainerMismatch
    }
    let evaluatedProjectURL = try absoluteURL(
      first.snapshot,
      role: .projectFilePath,
      isDirectory: true
    )
    guard
      let manifestProjectURL = manifestProjectContainerURL(
        manifestURL: manifestURL,
        containerName: manifest.project.containerName
      )
    else {
      throw ResolvedBuildPlanRejection.projectContainerMismatch
    }
    if let requestContainer = request.request.containerPath {
      guard requestContainer.str.hasPrefix("/") else {
        throw ResolvedBuildPlanRejection.projectContainerMismatch
      }
      let requestProjectURL = URL(
        fileURLWithPath: requestContainer.str,
        isDirectory: true
      ).standardizedFileURL
      guard requestProjectURL == evaluatedProjectURL else {
        throw ResolvedBuildPlanRejection.projectContainerMismatch
      }
    }
    guard evaluatedProjectURL == manifestProjectURL else {
      return .unrelated
    }
    return .proxyOwned(evaluatedProjectURL)
  }

  private static func manifestProjectContainerURL(
    manifestURL: URL,
    containerName: String
  ) -> URL? {
    guard manifestURL.isFileURL, manifestURL.path.hasPrefix("/") else { return nil }
    var candidate = manifestURL.deletingLastPathComponent().standardizedFileURL
    while candidate.path != "/" {
      if candidate.lastPathComponent == containerName {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    return nil
  }

  private static func commonAbsoluteURL(
    _ targetInputs: [TargetInput],
    preferredRole: ResolvedBuildPlanSettingRole,
    fallbackRole: ResolvedBuildPlanSettingRole
  ) throws -> URL {
    guard let first = targetInputs.first else {
      throw ResolvedBuildPlanRejection.invalidPath(targetGUID: "", role: preferredRole.rawValue)
    }
    if nonempty(first.snapshot.value(for: preferredRole)) != nil {
      return try absoluteURL(first.snapshot, role: preferredRole, isDirectory: true)
    }
    return try absoluteURL(first.snapshot, role: fallbackRole, isDirectory: true)
  }

  private static func validateRequiredPlanRoles(
    _ snapshot: PerTargetExportedSettingsSnapshot
  ) throws {
    for role in ResolvedBuildPlanSettingRole.allCases {
      guard let value = nonempty(snapshot.value(for: role)),
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw ResolvedBuildPlanRejection.invalidSetting(
          targetGUID: snapshot.targetGUID,
          key: role.rawValue
        )
      }
    }
  }

  private static func validateTargetIdentity(
    _ targetInput: TargetInput,
    mapping: BuildProxyManifest.Target
  ) throws {
    guard targetInput.configuredTarget.guid == mapping.xcodeTargetGUID,
      targetInput.snapshot.value(for: .bazelLabel) == mapping.bazelLabel,
      targetInput.snapshot.value(for: .bazelTargetID) == mapping.targetID
    else {
      throw ResolvedBuildPlanRejection.targetIdentityMismatch(
        targetGUID: targetInput.configuredTarget.guid
      )
    }
  }

  private static func resolveProductPaths(
    _ targetInput: TargetInput,
    mapping: BuildProxyManifest.Target
  ) throws -> ResolvedProductPaths? {
    guard mapping.product.materialization != .none else { return nil }
    guard let manifestProductPath = mapping.product.path,
      manifestProductPath.hasPrefix("bazel-out/")
    else {
      throw ResolvedBuildPlanRejection.invalidPath(
        targetGUID: targetInput.configuredTarget.guid,
        role: "manifest.product.path"
      )
    }
    let fullProductName = targetInput.snapshot.value(for: .fullProductName) ?? ""
    guard fullProductName == mapping.product.basename else {
      throw ResolvedBuildPlanRejection.productBasenameMismatch(
        targetGUID: targetInput.configuredTarget.guid
      )
    }
    let bazelOutputRoot = try absoluteURL(
      targetInput.snapshot,
      role: .bazelOutputDirectory,
      isDirectory: true
    )
    let targetBuildDirectory = try absoluteURL(
      targetInput.snapshot,
      role: .targetBuildDirectory,
      isDirectory: true
    )
    let sourceSuffix = String(manifestProductPath.dropFirst("bazel-out/".count))
    return ResolvedProductPaths(
      bazelOutputRootURL: bazelOutputRoot,
      destinationProductURL: targetBuildDirectory.appendingPathComponent(
        fullProductName,
        isDirectory: mapping.product.materialization == .copyTree
      ).standardizedFileURL,
      fullProductName: fullProductName,
      sourceProductURL: bazelOutputRoot.appendingPathComponent(
        sourceSuffix,
        isDirectory: mapping.product.materialization == .copyTree
      ).standardizedFileURL,
      targetBuildDirectoryURL: targetBuildDirectory
    )
  }

  private static func validatePreviewAgreement(
    intent: BuildIntent,
    targetInputs: [TargetInput]
  ) throws {
    let expected = intent.mode == .preview ? "YES" : "NO"
    for input in targetInputs {
      guard input.snapshot.value(for: .previewsEnabled) == expected else {
        throw ResolvedBuildPlanRejection.invalidSetting(
          targetGUID: input.configuredTarget.guid,
          key: ResolvedBuildPlanSettingRole.previewsEnabled.rawValue
        )
      }
    }
  }

  private static func validateIntegrationDirectory(
    targetInputs: [TargetInput],
    manifestURL: URL
  ) throws {
    guard manifestURL.isFileURL, manifestURL.path.hasPrefix("/"),
      let first = targetInputs.first,
      let value = nonempty(first.snapshot.value(for: .bazelIntegrationDirectory)),
      value.hasPrefix("/"),
      URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        == manifestURL.deletingLastPathComponent().standardizedFileURL
    else {
      throw ResolvedBuildPlanRejection.manifestDirectoryMismatch
    }
  }

  private static func validateAdapterAction(
    intent: BuildIntent,
    targetInputs: [TargetInput]
  ) throws {
    guard intent.action != .clean else { return }
    for input in targetInputs {
      guard input.snapshot.value(forKey: "ACTION") == input.parameters.action,
        nonempty(input.snapshot.value(forKey: "BAZEL_CONFIG")) != nil
      else {
        throw ResolvedBuildPlanRejection.invalidSetting(
          targetGUID: input.configuredTarget.guid,
          key: "ACTION/BAZEL_CONFIG"
        )
      }
    }
  }

  private static func makeAdapterEnvironment(
    targetInputs: [TargetInput],
    manifest: BuildProxyManifest
  ) throws -> [String: String] {
    guard let first = targetInputs.first else { return [:] }
    var result = [String: String]()
    for key in manifest.invocation.environmentKeys {
      guard let value = nonempty(first.snapshot.value(forKey: key)) else { continue }
      guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw ResolvedBuildPlanRejection.invalidSetting(
          targetGUID: first.configuredTarget.guid,
          key: key
        )
      }
      result[key] = value
    }
    return result
  }

  private static func validateOperationID(_ operationID: String) throws {
    guard !operationID.isEmpty else { throw ResolvedBuildPlanRejection.emptyOperationID }
    guard operationID != ".", operationID != "..", !operationID.contains("/"),
      !operationID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ResolvedBuildPlanRejection.unsafeOperationID
    }
  }

  private static func validateManifestIdentity(
    _ identity: BuildProxyManifestFileIdentity
  ) throws {
    guard identity.algorithm == "sha256", identity.byteSize > 0,
      identity.hex.utf8.count == 64,
      identity.hex.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      })
    else {
      throw ResolvedBuildPlanRejection.invalidManifestIdentity
    }
  }

  private static func absoluteURL(
    _ snapshot: PerTargetExportedSettingsSnapshot,
    role: ResolvedBuildPlanSettingRole,
    isDirectory: Bool
  ) throws -> URL {
    guard let value = nonempty(snapshot.value(for: role)), value.hasPrefix("/"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ResolvedBuildPlanRejection.invalidPath(
        targetGUID: snapshot.targetGUID,
        role: role.rawValue
      )
    }
    return URL(fileURLWithPath: value, isDirectory: isDirectory).standardizedFileURL
  }

  private static func normalizedArchitecture(_ value: String?) -> String? {
    guard let value = nonempty(value), value != "undefined_arch" else { return nil }
    return value
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
