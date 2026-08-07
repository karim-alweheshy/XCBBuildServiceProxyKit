import Foundation

public enum NativeForwardReason: Equatable, Sendable {
  case ignoredTargetsOnly
  case noRequestedTargets
  case unmappedTarget(String)
  case unsupportedAction(String)
  case unsupportedMode(String)
  case unsupportedSchemeAction(String)
}

public enum TargetRoutingError: LocalizedError, Equatable, Sendable {
  case ambiguousTarget(String)
  case capabilityNotDeclared(String)
  case staleTarget(String)

  public var errorDescription: String? {
    switch self {
    case .ambiguousTarget(let target):
      return "The manifest has more than one eligible mapping for \(target)."
    case .capabilityNotDeclared(let capability):
      return "The manifest does not declare the \(capability) capability."
    case .staleTarget(let target):
      return "The manifest has no eligible mapping for the explicit Bazel target \(target)."
    }
  }
}

public enum RoutingDecision: Equatable, Sendable {
  case forwardNative(NativeForwardReason)
  case intercept([BuildProxyManifest.Target])
  case reject(TargetRoutingError)
}

public enum TargetResolver {
  public static func resolve(
    intent: BuildIntent,
    manifest: BuildProxyManifest
  ) -> RoutingDecision {
    guard !intent.requestedTargets.isEmpty else {
      return .forwardNative(.noRequestedTargets)
    }

    let capability: String
    switch intent.action {
    case .build:
      switch intent.mode {
      case .standard:
        capability = "build"
      case .preview:
        capability = "preview"
      case .unsupported(let value):
        return .forwardNative(.unsupportedMode(value))
      }
    case .clean:
      guard case .standard = intent.mode else {
        return forwardReason(for: intent.mode)
      }
      capability = "clean"
    case .indexBuild:
      guard case .standard = intent.mode else {
        return forwardReason(for: intent.mode)
      }
      capability = "indexbuild"
    case .unsupported(let value):
      return .forwardNative(.unsupportedAction(value))
    }

    guard intent.schemeAction == "build" else {
      return .forwardNative(.unsupportedSchemeAction(intent.schemeAction))
    }
    guard manifest.capabilities.actions.contains(capability) else {
      return .reject(.capabilityNotDeclared(capability))
    }

    let ignoredGUIDs = Set(manifest.ignoredXcodeTargetGUIDs)
    var resolvedTargets = [BuildProxyManifest.Target]()
    var seenTargetIDs = Set<String>()
    var sawNonIgnoredTarget = false

    for requestedTarget in intent.requestedTargets {
      if ignoredGUIDs.contains(requestedTarget.xcodeTargetGUID) {
        continue
      }
      sawNonIgnoredTarget = true

      let candidates = manifest.targets.filter { target in
        target.configuration == intent.configuration
          && target.action == "build"
          && intent.platform.map { target.variant.platform == $0 } ?? true
          && intent.architecture.map { target.variant.arch == $0 } ?? true
          && matchesIdentity(requestedTarget: requestedTarget, manifestTarget: target)
      }

      if candidates.isEmpty {
        if requestedTarget.targetID != nil || requestedTarget.bazelLabel != nil {
          return .reject(.staleTarget(identityDescription(requestedTarget)))
        }
        return .forwardNative(.unmappedTarget(identityDescription(requestedTarget)))
      }
      guard candidates.count == 1, let candidate = candidates.first else {
        return .reject(.ambiguousTarget(identityDescription(requestedTarget)))
      }
      if seenTargetIDs.insert(candidate.targetID).inserted {
        resolvedTargets.append(candidate)
      }
    }

    guard sawNonIgnoredTarget else {
      return .forwardNative(.ignoredTargetsOnly)
    }
    return .intercept(resolvedTargets)
  }

  private static func matchesIdentity(
    requestedTarget: RequestedTarget,
    manifestTarget: BuildProxyManifest.Target
  ) -> Bool {
    if let targetID = requestedTarget.targetID {
      return manifestTarget.targetID == targetID
    }
    if let bazelLabel = requestedTarget.bazelLabel {
      return manifestTarget.bazelLabel == bazelLabel
    }
    return manifestTarget.xcodeTargetGUID == requestedTarget.xcodeTargetGUID
  }

  private static func identityDescription(_ target: RequestedTarget) -> String {
    target.targetID ?? target.bazelLabel ?? target.xcodeTargetGUID
  }

  private static func forwardReason(for mode: BuildIntentMode) -> RoutingDecision {
    switch mode {
    case .preview:
      return .forwardNative(.unsupportedMode("preview"))
    case .unsupported(let value):
      return .forwardNative(.unsupportedMode(value))
    case .standard:
      preconditionFailure("standard mode was checked before requesting a forward reason")
    }
  }
}
