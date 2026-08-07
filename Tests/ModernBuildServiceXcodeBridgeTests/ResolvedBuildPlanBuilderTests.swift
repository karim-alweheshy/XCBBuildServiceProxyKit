import BazelProxyCore
import CryptoKit
import Foundation
import SWBProtocol
import SWBUtil
import XCTest

@testable import ModernBuildServiceXcodeBridge

final class ResolvedBuildPlanBuilderTests: XCTestCase {
  func testBuildDescriptionOnlyForwardsWithoutSettingsSnapshots() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      onlyCreateBuildDescription: true
    )

    XCTAssertEqual(
      fixture.resolve(request: request, snapshots: []),
      .forwardNative(.buildDescriptionOnly)
    )
  }

  func testLaunchRequestUsesBuildActionAndDerivesProductsAndAllowlistedEnvironment() throws {
    let fixture = try PlanBuilderFixture()
    let snapshot = fixture.snapshot(
      targetGUID: "APP_GUID",
      extras: ["UNRELATED_SECRET": "must-not-cross"]
    )
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      parameters: planParameters(platform: "iphonesimulator")
    )

    let decision = fixture.resolve(request: request, snapshots: [snapshot])

    guard case .intercept(let plan) = decision else {
      return XCTFail("Expected interception, got \(decision)")
    }
    XCTAssertEqual(plan.operationID, "operation-1")
    XCTAssertEqual(plan.intent.action, .build)
    XCTAssertEqual(plan.intent.mode, .standard)
    XCTAssertEqual(plan.intent.schemeAction, "build")
    XCTAssertEqual(plan.intent.configuration, "Debug")
    XCTAssertEqual(plan.intent.platform, "iphonesimulator")
    XCTAssertEqual(plan.intent.architecture, "arm64")
    XCTAssertEqual(plan.intent.projectContainerURL, fixture.projectURL.standardizedFileURL)
    XCTAssertEqual(plan.intent.workspaceURL, fixture.workspaceURL.standardizedFileURL)
    XCTAssertEqual(plan.adapterRequest.labels, ["//app:App"])
    XCTAssertEqual(plan.adapterRequest.outputGroups, ["bp app-app"])
    XCTAssertEqual(plan.adapterRequest.targetIDs, ["app-app"])
    XCTAssertEqual(Set(plan.evaluatedEnvironment.keys), Set(fixture.environmentKeys))
    XCTAssertNil(plan.evaluatedEnvironment["UNRELATED_SECRET"])
    XCTAssertFalse(snapshot.values.contains { $0.key == "UNRELATED_SECRET" })

    let productPaths = try XCTUnwrap(plan.targets.first?.productPaths)
    XCTAssertEqual(
      productPaths.sourceProductURL,
      fixture.bazelOutputURL
        .appendingPathComponent("products/App.app", isDirectory: true)
        .standardizedFileURL
    )
    XCTAssertEqual(
      productPaths.destinationProductURL,
      fixture.targetBuildURL
        .appendingPathComponent("App.app", isDirectory: true)
        .standardizedFileURL
    )
    XCTAssertEqual(productPaths.fullProductName, "App.app")
  }

  func testCleanNeverRequestsAdapterTargetsOrOutputGroups() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      buildCommand: .cleanBuildFolder(style: .regular)
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [fixture.snapshot(targetGUID: "APP_GUID")]
    )

    guard case .intercept(let plan) = decision else {
      return XCTFail("Expected interception, got \(decision)")
    }
    XCTAssertEqual(plan.intent.action, .clean)
    XCTAssertEqual(plan.intent.mode, .standard)
    XCTAssertEqual(plan.intent.schemeAction, "build")
    XCTAssertEqual(plan.adapterRequest, AdapterRequest(labels: [], outputGroups: [], targetIDs: []))
  }

  func testIndexBuildUsesIndexOutputGroupsAndNormalizesSchemeAction() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      parameters: planParameters(action: "indexbuild")
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID", overrides: ["ACTION": "indexbuild"])
      ]
    )

    guard case .intercept(let plan) = decision else {
      return XCTFail("Expected interception, got \(decision)")
    }
    XCTAssertEqual(plan.intent.action, .indexBuild)
    XCTAssertEqual(plan.intent.mode, .standard)
    XCTAssertEqual(plan.intent.schemeAction, "build")
    XCTAssertEqual(plan.adapterRequest.outputGroups, ["bc app-app", "bi app-app"])
  }

  func testPrepareForIndexingIsNotMisclassifiedAsObservedIndexBuild() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      buildCommand: .prepareForIndexing(
        buildOnlyTheseTargets: nil,
        enableIndexBuildArena: true
      )
    )

    XCTAssertEqual(
      fixture.resolve(
        request: request,
        snapshots: [fixture.snapshot(targetGUID: "APP_GUID")]
      ),
      .forwardNative(.unsupportedAction("prepareForIndexing"))
    )
  }

  func testPreviewRequiresEvaluatedAgreementAndUsesPreviewOutputGroups() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      buildCommand: .preview(style: .dynamicReplacement)
    )

    let accepted = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID", overrides: ["ENABLE_PREVIEWS": "YES"])
      ]
    )
    guard case .intercept(let plan) = accepted else {
      return XCTFail("Expected preview interception, got \(accepted)")
    }
    XCTAssertEqual(plan.intent.action, .build)
    XCTAssertEqual(plan.intent.mode, .preview)
    XCTAssertEqual(plan.adapterRequest.outputGroups, ["bc app-app", "bp app-app", "bl app-app"])

    let rejected = fixture.resolve(
      request: request,
      snapshots: [fixture.snapshot(targetGUID: "APP_GUID")]
    )
    XCTAssertEqual(
      rejected,
      .reject(.invalidSetting(targetGUID: "APP_GUID", key: "ENABLE_PREVIEWS"))
    )
  }

  func testEffectiveTargetParametersMustAgreeAcrossOperation() throws {
    let fixture = try PlanBuilderFixture(includeSecondTarget: true)
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil),
        ConfiguredTargetMessagePayload(
          guid: "EXT_GUID",
          parameters: planParameters(configuration: "Release")
        ),
      ]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID"),
        fixture.snapshot(targetGUID: "EXT_GUID"),
      ]
    )

    XCTAssertEqual(decision, .reject(.effectiveParametersDisagree("configuration")))
  }

  func testOperationWideExportedSettingsMustAgreeAcrossTargets() throws {
    let fixture = try PlanBuilderFixture(includeSecondTarget: true)
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil),
        ConfiguredTargetMessagePayload(guid: "EXT_GUID", parameters: nil),
      ]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID"),
        fixture.snapshot(targetGUID: "EXT_GUID", overrides: ["HOME": "/different-home"]),
      ]
    )

    XCTAssertEqual(decision, .reject(.operationWideSettingDisagreement("HOME")))
  }

  func testCrossTargetProjectIdentityDisagreementRejects() throws {
    let fixture = try PlanBuilderFixture(includeSecondTarget: true)
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil),
        ConfiguredTargetMessagePayload(guid: "EXT_GUID", parameters: nil),
      ]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID"),
        fixture.snapshot(
          targetGUID: "EXT_GUID",
          overrides: [
            "PROJECT_FILE_PATH": fixture.rootURL
              .appendingPathComponent("Different.xcodeproj", isDirectory: true).path
          ]
        ),
      ]
    )

    XCTAssertEqual(
      decision,
      .reject(.operationWideSettingDisagreement("PROJECT_FILE_PATH"))
    )
  }

  func testMixedMappedAndUnmappedTargetsForwardEntireOperationToNative() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [
        ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil),
        ConfiguredTargetMessagePayload(guid: "NATIVE_GUID", parameters: nil),
      ]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID"),
        fixture.snapshot(
          targetGUID: "NATIVE_GUID",
          overrides: [
            "BAZEL_LABEL": "",
            "BAZEL_TARGET_ID": "",
            "FULL_PRODUCT_NAME": "Native.framework",
            "TARGET_NAME": "Native",
          ]
        ),
      ]
    )

    XCTAssertEqual(decision, .forwardNative(.unmappedTarget("NATIVE_GUID")))
  }

  func testClearlyUnrelatedProjectForwardsEntireOperationToNative() throws {
    let fixture = try PlanBuilderFixture()
    let unrelatedProjectURL = fixture.rootURL.appendingPathComponent(
      "Unrelated.xcodeproj",
      isDirectory: true
    )
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(
          targetGUID: "APP_GUID",
          overrides: ["PROJECT_FILE_PATH": unrelatedProjectURL.path]
        )
      ]
    )

    XCTAssertEqual(decision, .forwardNative(.unrelatedProject))
  }

  func testRequestAndEvaluatedProjectDisagreementRejects() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      containerPath: Path(
        fixture.rootURL.appendingPathComponent("Different.xcodeproj", isDirectory: true).path
      )
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [fixture.snapshot(targetGUID: "APP_GUID")]
    )

    XCTAssertEqual(decision, .reject(.projectContainerMismatch))
  }

  func testStaleExplicitMappingRejectsInsteadOfFallingBack() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(
          targetGUID: "APP_GUID",
          overrides: [
            "BAZEL_LABEL": "//stale:App",
            "BAZEL_TARGET_ID": "stale-app",
          ]
        )
      ]
    )

    XCTAssertEqual(decision, .reject(.routing(.staleTarget("stale-app"))))
  }

  func testResolvedMappingMustMatchBothExplicitIdentities() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(
          targetGUID: "APP_GUID",
          overrides: ["BAZEL_LABEL": "//stale:App"]
        )
      ]
    )

    XCTAssertEqual(decision, .reject(.targetIdentityMismatch(targetGUID: "APP_GUID")))
  }

  func testAmbiguousImplicitMappingRejects() throws {
    let fixture = try PlanBuilderFixture(includeAmbiguousTarget: true)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(
          targetGUID: "APP_GUID",
          overrides: ["BAZEL_LABEL": "", "BAZEL_TARGET_ID": ""]
        )
      ]
    )

    XCTAssertEqual(decision, .reject(.routing(.ambiguousTarget("APP_GUID"))))
  }

  func testMappedTargetWithEmptyRequiredRoleRejects() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID", overrides: ["BAZEL_OUT": ""])
      ]
    )

    XCTAssertEqual(
      decision,
      .reject(.invalidSetting(targetGUID: "APP_GUID", key: "BAZEL_OUT"))
    )
  }

  func testMappedTargetRequiresBazelWorkspaceRootEvenWhenSourceRootExists() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [
        fixture.snapshot(targetGUID: "APP_GUID", overrides: ["BAZEL_WORKSPACE_ROOT": ""])
      ]
    )

    XCTAssertEqual(
      decision,
      .reject(.invalidSetting(targetGUID: "APP_GUID", key: "BAZEL_WORKSPACE_ROOT"))
    )
  }

  func testUndefinedActiveArchitectureFallsBackToRunDestinationArchitecture() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)],
      parameters: planParameters(
        platform: "iphonesimulator",
        activeArchitecture: "undefined_arch"
      )
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [fixture.snapshot(targetGUID: "APP_GUID")]
    )

    guard case .intercept(let plan) = decision else {
      return XCTFail("Expected interception, got \(decision)")
    }
    XCTAssertEqual(plan.intent.architecture, "arm64")
  }

  func testSnapshotFromDifferentVerifiedManifestRejects() throws {
    let fixture = try PlanBuilderFixture()
    let otherFixture = try PlanBuilderFixture(includeSecondTarget: true)
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    let decision = fixture.resolve(
      request: request,
      snapshots: [otherFixture.snapshot(targetGUID: "APP_GUID")]
    )

    XCTAssertEqual(decision, .reject(.manifestIdentityMismatch(targetGUID: "APP_GUID")))
  }

  func testMissingSnapshotRejectsBeforePlanning() throws {
    let fixture = try PlanBuilderFixture()
    let request = makeCreateBuildRequest(
      targets: [ConfiguredTargetMessagePayload(guid: "APP_GUID", parameters: nil)]
    )

    XCTAssertEqual(
      fixture.resolve(request: request, snapshots: []),
      .reject(.missingSettingsSnapshot("APP_GUID"))
    )
  }
}

private final class PlanBuilderFixture {
  let bazelOutputURL: URL
  let environmentKeys = [
    "ACTION",
    "BAZEL_CONFIG",
    "BAZEL_INTEGRATION_DIR",
    "BAZEL_OUT",
    "ENABLE_PREVIEWS",
    "HOME",
    "SRCROOT",
  ]
  let integrationURL: URL
  let manifestURL: URL
  let projectURL: URL
  let rootURL: URL
  let targetBuildURL: URL
  let verifiedManifest: VerifiedBuildProxyManifest
  let workspaceURL: URL

  init(
    includeSecondTarget: Bool = false,
    includeAmbiguousTarget: Bool = false
  ) throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ResolvedBuildPlanBuilderTests-\(UUID().uuidString)",
      isDirectory: true
    )
    projectURL = rootURL.appendingPathComponent("App.xcodeproj", isDirectory: true)
    integrationURL = projectURL.appendingPathComponent("rules_xcodeproj/bazel", isDirectory: true)
    manifestURL = integrationURL.appendingPathComponent("build-proxy-manifest.json")
    workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    bazelOutputURL = workspaceURL.appendingPathComponent("bazel-out", isDirectory: true)
    targetBuildURL = rootURL.appendingPathComponent(
      "Derived/Debug-iphonesimulator", isDirectory: true)
    try FileManager.default.createDirectory(at: integrationURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

    var targets = [Self.target()]
    if includeSecondTarget {
      targets.append(
        Self.target(
          bazelLabel: "//app:Extension",
          productBasename: "Extension.appex",
          targetID: "app-extension",
          xcodeTargetGUID: "EXT_GUID"
        )
      )
    }
    if includeAmbiguousTarget {
      targets.append(
        Self.target(
          bazelLabel: "//app:AlternateApp",
          productBasename: "AlternateApp.app",
          targetID: "alternate-app",
          xcodeTargetGUID: "APP_GUID"
        )
      )
    }

    let manifest: [String: Any] = [
      "capabilities": ["actions": ["build", "clean", "indexbuild", "preview"]],
      "ignoredXcodeTargetGUIDs": [],
      "invocation": [
        "adapterPath": "rules_xcodeproj/bazel/generate_bazel_dependencies.sh",
        "bazelPath": "/usr/bin/bazel",
        "bazelrcPath": "rules_xcodeproj/bazel/xcodeproj.bazelrc",
        "environmentKeys": environmentKeys,
        "generatorLabel": "//app:AppProject",
        "receiptSchemaVersion": 1,
      ],
      "project": [
        "containerName": "App.xcodeproj",
        "identity": "project-identity",
      ],
      "schemaVersion": 2,
      "targets": targets,
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try data.write(to: manifestURL, options: .atomic)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    verifiedManifest = try BuildProxyManifest.loadVerified(
      from: manifestURL,
      expecting: BuildProxyManifestExpectation(
        projectContainerURL: projectURL,
        projectIdentity: "project-identity"
      ),
      expectedSHA256: digest
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: rootURL)
  }

  func resolve(
    request: CreateBuildRequest,
    snapshots: [PerTargetExportedSettingsSnapshot]
  ) -> ResolvedBuildPlanDecision {
    ResolvedBuildPlanBuilder.resolve(
      operationID: "operation-1",
      request: request,
      manifestURL: manifestURL,
      verifiedManifest: verifiedManifest,
      settingsSnapshots: snapshots
    )
  }

  func snapshot(
    targetGUID: String,
    overrides: [String: String] = [:],
    extras: [String: String] = [:]
  ) -> PerTargetExportedSettingsSnapshot {
    let isExtension = targetGUID == "EXT_GUID"
    var values = [
      "ACTION": "build",
      "BAZEL_CONFIG": "rules_xcodeproj",
      "BAZEL_INTEGRATION_DIR": integrationURL.path,
      "BAZEL_LABEL": isExtension ? "//app:Extension" : "//app:App",
      "BAZEL_OUT": bazelOutputURL.path,
      "BAZEL_TARGET_ID": isExtension ? "app-extension" : "app-app",
      "BAZEL_WORKSPACE_ROOT": workspaceURL.path,
      "ENABLE_PREVIEWS": "NO",
      "FULL_PRODUCT_NAME": isExtension ? "Extension.appex" : "App.app",
      "HOME": "/safe-home",
      "PROJECT_FILE_PATH": projectURL.path,
      "PROJECT_NAME": "App",
      "SRCROOT": workspaceURL.path,
      "TARGET_BUILD_DIR": targetBuildURL.path,
      "TARGET_NAME": isExtension ? "Extension" : "App",
    ]
    values.merge(extras) { _, new in new }
    values.merge(overrides) { _, new in new }
    return PerTargetExportedSettingsSnapshot(
      targetGUID: targetGUID,
      exportedValues: values,
      verifiedManifest: verifiedManifest
    )
  }

  private static func target(
    bazelLabel: String = "//app:App",
    productBasename: String = "App.app",
    targetID: String = "app-app",
    xcodeTargetGUID: String = "APP_GUID"
  ) -> [String: Any] {
    [
      "action": "build",
      "bazelLabel": bazelLabel,
      "configuration": "Debug",
      "indexOutputGroups": ["bc \(targetID)", "bi \(targetID)"],
      "outputGroup": "bp \(targetID)",
      "previewOutputGroups": ["bc \(targetID)", "bp \(targetID)", "bl \(targetID)"],
      "product": [
        "basename": productBasename,
        "materialization": "copy_tree",
        "name": productBasename,
        "path": "bazel-out/products/\(productBasename)",
        "type": "com.apple.product-type.application",
      ],
      "targetID": targetID,
      "variant": [
        "arch": "arm64",
        "minimumOSVersion": "17.0",
        "platform": "iphonesimulator",
      ],
      "xcodeTargetGUID": xcodeTargetGUID,
    ]
  }
}

private func planParameters(
  action: String = "build",
  configuration: String = "Debug",
  platform: String? = nil,
  activeArchitecture: String? = "arm64"
) -> BuildParametersMessagePayload {
  BuildParametersMessagePayload(
    action: action,
    configuration: configuration,
    activeRunDestination: platform.map {
      RunDestinationInfo(
        buildTarget: .toolchainSDK(platform: $0, sdk: $0, sdkVariant: nil),
        targetArchitecture: "arm64",
        supportedArchitectures: OrderedSet(["arm64"]),
        disableOnlyActiveArch: false
      )
    },
    activeArchitecture: activeArchitecture,
    arenaInfo: nil,
    overrides: SettingsOverridesMessagePayload(
      synthesized: [:],
      commandLine: [:],
      commandLineConfigPath: nil,
      commandLineConfig: [:],
      environmentConfigPath: nil,
      environmentConfig: [:],
      toolchainOverride: nil
    )
  )
}
