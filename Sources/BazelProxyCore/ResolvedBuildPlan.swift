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

/// Evaluated product paths supplied by the bridge as one indivisible trust boundary.
///
/// Core verifies both leaf URLs against the declared roots before copying or cleaning. It never
/// treats an arbitrary absolute leaf URL as authority to mutate that path.
public struct ResolvedProductPaths: Equatable, Sendable {
  public let bazelOutputRootURL: URL
  public let destinationProductURL: URL
  public let fullProductName: String
  public let sourceProductURL: URL
  public let targetBuildDirectoryURL: URL

  public init(
    bazelOutputRootURL: URL,
    destinationProductURL: URL,
    fullProductName: String,
    sourceProductURL: URL,
    targetBuildDirectoryURL: URL
  ) {
    self.bazelOutputRootURL = bazelOutputRootURL
    self.destinationProductURL = destinationProductURL
    self.fullProductName = fullProductName
    self.sourceProductURL = sourceProductURL
    self.targetBuildDirectoryURL = targetBuildDirectoryURL
  }
}

public struct ResolvedTargetPlan: Equatable, Sendable {
  public let mapping: BuildProxyManifest.Target
  public let productPaths: ResolvedProductPaths?

  public init(mapping: BuildProxyManifest.Target, productPaths: ResolvedProductPaths?) {
    self.mapping = mapping
    self.productPaths = productPaths
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
