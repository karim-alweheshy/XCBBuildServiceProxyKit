import Foundation

public enum BuildIntentAction: Equatable, Sendable {
  case build
  case clean
  case indexBuild
  case unsupported(String)
}

public enum BuildIntentMode: Equatable, Sendable {
  case standard
  case preview
  case unsupported(String)
}

public struct RequestedTarget: Equatable, Sendable {
  public let bazelLabel: String?
  public let targetID: String?
  public let targetName: String
  public let xcodeTargetGUID: String

  public init(
    bazelLabel: String? = nil,
    targetID: String? = nil,
    targetName: String,
    xcodeTargetGUID: String
  ) {
    self.bazelLabel = bazelLabel
    self.targetID = targetID
    self.targetName = targetName
    self.xcodeTargetGUID = xcodeTargetGUID
  }
}

/// Neutral build-service input. This type deliberately does not depend on Swift Build protocol types.
public struct BuildIntent: Equatable, Sendable {
  /// The normalized command class. Indexing and preview remain distinct even though target entries
  /// use the schema-v2 `build` action.
  public let action: BuildIntentAction
  public let architecture: String?
  public let configuration: String
  public let mode: BuildIntentMode
  public let platform: String?
  public let projectContainerURL: URL
  public let requestedTargets: [RequestedTarget]
  /// The target action after bridge normalization. Schema v2 currently supports only `build`.
  public let schemeAction: String
  public let workspaceURL: URL

  public init(
    action: BuildIntentAction,
    architecture: String? = nil,
    configuration: String,
    mode: BuildIntentMode,
    platform: String? = nil,
    projectContainerURL: URL,
    requestedTargets: [RequestedTarget],
    schemeAction: String,
    workspaceURL: URL
  ) {
    self.action = action
    self.architecture = architecture
    self.configuration = configuration
    self.mode = mode
    self.platform = platform
    self.projectContainerURL = projectContainerURL
    self.requestedTargets = requestedTargets
    self.schemeAction = schemeAction
    self.workspaceURL = workspaceURL
  }
}
