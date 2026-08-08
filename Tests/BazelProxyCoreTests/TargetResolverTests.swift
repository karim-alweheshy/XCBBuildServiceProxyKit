import XCTest

@testable import BazelProxyCore

final class TargetResolverTests: XCTestCase {
  func testInterceptsMappedBuild() throws {
    let fixture = try ManifestFixture()
    let decision = TargetResolver.resolve(intent: fixture.intent(), manifest: try fixture.load())

    guard case .intercept(let targets) = decision else {
      return XCTFail("Expected interception, got \(decision)")
    }
    XCTAssertEqual(targets.map(\.targetID), ["app-app"])
  }

  func testRejectsStaleExplicitTarget() throws {
    let fixture = try ManifestFixture()
    let target = fixture.requestedTarget(
      bazelLabel: "//app:Removed",
      targetID: "removed",
      xcodeTargetGUID: "OLD_GUID"
    )

    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(requestedTargets: [target]),
        manifest: try fixture.load()
      ),
      .reject(.staleTarget("removed"))
    )
  }

  func testRejectsAmbiguousGUIDMapping() throws {
    let fixture = try ManifestFixture()
    var object = fixture.baseManifest()
    object["targets"] = [
      fixture.baseTarget(targetID: "app-one"),
      fixture.baseTarget(bazelLabel: "//app:AppTwo", targetID: "app-two"),
    ]
    try fixture.writeManifest(object)
    let target = fixture.requestedTarget(bazelLabel: nil, targetID: nil)

    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(requestedTargets: [target]),
        manifest: try fixture.load()
      ),
      .reject(.ambiguousTarget("APP_GUID"))
    )
  }

  func testIgnoresOnlyManifestDeclaredGUID() throws {
    let fixture = try ManifestFixture()
    let ignored = fixture.requestedTarget(
      bazelLabel: nil,
      targetID: nil,
      targetName: "BazelDependencies",
      xcodeTargetGUID: "BAZEL_DEPENDENCIES_GUID"
    )
    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(requestedTargets: [ignored]),
        manifest: try fixture.load()
      ),
      .forwardNative(.ignoredTargetsOnly)
    )

    let sameNameDifferentGUID = fixture.requestedTarget(
      bazelLabel: nil,
      targetID: nil,
      targetName: "BazelDependencies",
      xcodeTargetGUID: "APP_GUID"
    )
    guard
      case .intercept = TargetResolver.resolve(
        intent: fixture.intent(requestedTargets: [sameNameDifferentGUID]),
        manifest: try fixture.load()
      )
    else {
      return XCTFail("A target name must not implicitly opt out of Bazel routing")
    }
  }

  func testUnsupportedActionModeAndSchemeForwardNative() throws {
    let fixture = try ManifestFixture()
    let manifest = try fixture.load()
    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(action: .unsupported("archive")),
        manifest: manifest
      ),
      .forwardNative(.unsupportedAction("archive"))
    )
    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(mode: .unsupported("installAPI")),
        manifest: manifest
      ),
      .forwardNative(.unsupportedMode("installAPI"))
    )
    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(schemeAction: "analyze"),
        manifest: manifest
      ),
      .forwardNative(.unsupportedSchemeAction("analyze"))
    )
  }

  func testCleanIndexAndPreviewAreExplicitlyInterceptable() throws {
    let fixture = try ManifestFixture()
    let manifest = try fixture.load()
    for intent in [
      fixture.intent(action: .clean),
      fixture.intent(action: .indexBuild),
      fixture.intent(mode: .preview),
    ] {
      guard
        case .intercept(let targets) = TargetResolver.resolve(intent: intent, manifest: manifest)
      else {
        return XCTFail("Expected interception for \(intent)")
      }
      XCTAssertEqual(targets.map(\.targetID), ["app-app"])
    }
  }

  func testUnmappedGUIDWithoutExplicitBazelIdentityForwardsNative() throws {
    let fixture = try ManifestFixture()
    let target = fixture.requestedTarget(
      bazelLabel: nil,
      targetID: nil,
      targetName: "NativeLibrary",
      xcodeTargetGUID: "NATIVE_GUID"
    )
    XCTAssertEqual(
      TargetResolver.resolve(
        intent: fixture.intent(requestedTargets: [target]),
        manifest: try fixture.load()
      ),
      .forwardNative(.unmappedTarget("NATIVE_GUID"))
    )
  }
}
