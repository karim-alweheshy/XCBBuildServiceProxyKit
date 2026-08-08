import Foundation

@testable import BazelProxyCore

final class ManifestFixture {
  let adapterURL: URL
  let manifestURL: URL
  let projectURL: URL
  let rootURL: URL
  let workspaceURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BazelProxyCoreTests-\(UUID().uuidString)",
      isDirectory: true
    )
    projectURL = rootURL.appendingPathComponent("App.xcodeproj", isDirectory: true)
    workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    let integrationURL = projectURL.appendingPathComponent(
      "rules_xcodeproj/bazel", isDirectory: true)
    adapterURL = integrationURL.appendingPathComponent("generate_bazel_dependencies.sh")
    manifestURL = integrationURL.appendingPathComponent("build-proxy-manifest.json")

    try FileManager.default.createDirectory(
      at: integrationURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    guard
      FileManager.default.createFile(
        atPath: adapterURL.path,
        contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755]
      )
    else {
      throw FixtureError.creationFailed(adapterURL.path)
    }
    let bazelrcURL = integrationURL.appendingPathComponent("xcodeproj.bazelrc")
    guard FileManager.default.createFile(atPath: bazelrcURL.path, contents: Data()) else {
      throw FixtureError.creationFailed(bazelrcURL.path)
    }
    try writeManifest(baseManifest())
  }

  deinit {
    try? FileManager.default.removeItem(at: rootURL)
  }

  func load(projectIdentity: String? = "project-identity") throws -> BuildProxyManifest {
    try BuildProxyManifest.load(
      from: manifestURL,
      expecting: BuildProxyManifestExpectation(
        projectContainerURL: projectURL,
        projectIdentity: projectIdentity
      )
    )
  }

  func writeManifest(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: manifestURL, options: .atomic)
  }

  func baseManifest() -> [String: Any] {
    [
      "capabilities": ["actions": ["build", "clean", "indexbuild", "preview"]],
      "ignoredXcodeTargetGUIDs": ["BAZEL_DEPENDENCIES_GUID"],
      "invocation": [
        "adapterPath": "rules_xcodeproj/bazel/generate_bazel_dependencies.sh",
        "bazelPath": "/usr/local/bin/bazel",
        "bazelrcPath": "rules_xcodeproj/bazel/xcodeproj.bazelrc",
        "environmentKeys": [
          "ACTION", "BAZEL_CONFIG", "BAZEL_EXTERNAL", "BAZEL_INTEGRATION_DIR", "BAZEL_OUT",
          "BAZEL_OUTPUT_BASE", "BAZEL_SEPARATE_INDEXBUILD_OUTPUT_BASE",
          "BAZEL_SUPPRESS_COVERAGE_BUILD", "CLANG_COVERAGE_MAPPING", "COLOR_DIAGNOSTICS",
          "DEVELOPER_DIR", "ENABLE_ADDRESS_SANITIZER", "ENABLE_PREVIEWS",
          "ENABLE_THREAD_SANITIZER", "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER", "HOME",
          "IMPORT_INDEX_BUILD_INDEXSTORES", "INDEX_DATA_STORE_DIR", "INDEXING_PROJECT_DIR__NO",
          "OBJROOT", "PROJECT_DIR", "RULES_XCODEPROJ_BUILD_MODE", "SRCROOT", "TERM", "TOOLCHAINS",
          "USER", "XCODE_PRODUCT_BUILD_VERSION", "XCODE_VERSION_ACTUAL",
        ],
        "generatorLabel": "//app:AppProject",
        "receiptSchemaVersion": 1,
      ],
      "project": [
        "containerName": "App.xcodeproj",
        "identity": "project-identity",
      ],
      "schemaVersion": 2,
      "targets": [baseTarget()],
    ]
  }

  func baseTarget(
    arch: String = "arm64",
    bazelLabel: String = "//app:App",
    configuration: String = "Debug",
    materialization: String = "copy_tree",
    productBasename: String = "App.app",
    productName: String = "App",
    productType: String = "com.apple.product-type.application",
    targetID: String = "app-app",
    xcodeTargetGUID: String = "APP_GUID"
  ) -> [String: Any] {
    [
      "action": "build",
      "bazelLabel": bazelLabel,
      "configuration": configuration,
      "indexOutputGroups": ["bc \(targetID)", "bi \(targetID)"],
      "outputGroup": "bp \(targetID)",
      "previewOutputGroups": ["bc \(targetID)", "bp \(targetID)", "bl \(targetID)"],
      "product": [
        "basename": productBasename,
        "materialization": materialization,
        "name": productName,
        "path": "bazel-out/products/\(productBasename)",
        "type": productType,
      ],
      "targetID": targetID,
      "variant": [
        "arch": arch,
        "minimumOSVersion": "17.0",
        "platform": "iphonesimulator",
      ],
      "xcodeTargetGUID": xcodeTargetGUID,
    ]
  }

  func intent(
    action: BuildIntentAction = .build,
    architecture: String? = "arm64",
    mode: BuildIntentMode = .standard,
    platform: String? = "iphonesimulator",
    requestedTargets: [RequestedTarget]? = nil,
    schemeAction: String = "build"
  ) -> BuildIntent {
    BuildIntent(
      action: action,
      architecture: architecture,
      configuration: "Debug",
      mode: mode,
      platform: platform,
      projectContainerURL: projectURL,
      requestedTargets: requestedTargets ?? [requestedTarget()],
      schemeAction: schemeAction,
      workspaceURL: workspaceURL
    )
  }

  func requestedTarget(
    bazelLabel: String? = "//app:App",
    targetID: String? = "app-app",
    targetName: String = "App",
    xcodeTargetGUID: String = "APP_GUID"
  ) -> RequestedTarget {
    RequestedTarget(
      bazelLabel: bazelLabel,
      targetID: targetID,
      targetName: targetName,
      xcodeTargetGUID: xcodeTargetGUID
    )
  }

  func plan(
    evaluatedEnvironment: [String: String] = [
      "ACTION": "build",
      "BAZEL_CONFIG": "rules_xcodeproj",
      "SRCROOT": "/workspace",
    ],
    operationID: String = UUID().uuidString
  ) throws -> ResolvedBuildPlan {
    let manifest = try load()
    let mapping = manifest.targets[0]
    return ResolvedBuildPlan(
      adapterRequest: AdapterRequest(
        labels: [mapping.bazelLabel],
        outputGroups: [mapping.outputGroup],
        targetIDs: [mapping.targetID]
      ),
      evaluatedEnvironment: evaluatedEnvironment,
      intent: intent(),
      manifest: manifest,
      manifestURL: manifestURL,
      operationID: operationID,
      targets: [
        ResolvedTargetPlan(mapping: mapping, productPaths: nil)
      ]
    )
  }
}

enum FixtureError: Error {
  case creationFailed(String)
}

func mutableDictionary(_ object: [String: Any], key: String) throws -> [String: Any] {
  guard let dictionary = object[key] as? [String: Any] else {
    throw FixtureError.creationFailed("missing dictionary \(key)")
  }
  return dictionary
}
