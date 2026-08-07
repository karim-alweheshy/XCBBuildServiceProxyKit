import Foundation

/// Adapter input already selected by the build-service bridge. Core invocation code only serializes it.
public struct AdapterRequest: Equatable, Sendable {
  public let labels: [String]
  public let outputGroups: [String]
  public let targetIDs: [String]

  public init(labels: [String], outputGroups: [String], targetIDs: [String]) {
    self.labels = labels
    self.outputGroups = outputGroups
    self.targetIDs = targetIDs
  }
}

public struct ResolvedTargetPlan: Equatable, Sendable {
  public let destinationProductURL: URL?
  public let mapping: BuildProxyManifest.Target
  public let sourceProductURL: URL?

  public init(
    destinationProductURL: URL?,
    mapping: BuildProxyManifest.Target,
    sourceProductURL: URL?
  ) {
    self.destinationProductURL = destinationProductURL
    self.mapping = mapping
    self.sourceProductURL = sourceProductURL
  }
}

/// Contains only bridge-resolved values; it never evaluates settings or invents product paths.
public struct ResolvedBuildPlan: Equatable, Sendable {
  public let adapterRequest: AdapterRequest
  public let evaluatedEnvironment: [String: String]
  public let intent: BuildIntent
  public let manifest: BuildProxyManifest
  public let manifestURL: URL
  public let operationID: String
  public let targets: [ResolvedTargetPlan]

  public init(
    adapterRequest: AdapterRequest,
    evaluatedEnvironment: [String: String],
    intent: BuildIntent,
    manifest: BuildProxyManifest,
    manifestURL: URL,
    operationID: String,
    targets: [ResolvedTargetPlan]
  ) {
    self.adapterRequest = adapterRequest
    self.evaluatedEnvironment = evaluatedEnvironment
    self.intent = intent
    self.manifest = manifest
    self.manifestURL = manifestURL
    self.operationID = operationID
    self.targets = targets
  }
}
