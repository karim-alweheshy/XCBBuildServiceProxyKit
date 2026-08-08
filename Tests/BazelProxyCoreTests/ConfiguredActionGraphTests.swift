import Foundation
import XCTest

@testable import BazelProxyCore

final class ConfiguredActionGraphTests: XCTestCase {
  func testSelectsRequestedProductClosureAndIgnoresSensitiveUnknownFields() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = root.appendingPathComponent("configured-actions.json")
    try Data(Self.graphJSON.utf8).write(to: graph)

    let validation = try ConfiguredActionGraphValidator.validate(
      fileAt: graph,
      productPaths: ["bazel-out/sim/bin/App/App.app"],
      configurations: ["sim"]
    )

    XCTAssertEqual(
      validation.actions,
      [
        BazelConfiguredAction(
          configuration: "sim",
          label: "//app:App.library",
          mnemonic: "SwiftCompile",
          primaryOutput: "bazel-out/sim/bin/App/App.swiftmodule"
        ),
        BazelConfiguredAction(
          configuration: "sim",
          label: "//app:App",
          mnemonic: "BundleTreeApp",
          primaryOutput: "bazel-out/sim/bin/App/App.app"
        ),
      ]
    )
    XCTAssertFalse(String(describing: validation).contains("do-not-retain-action-graph-secret"))
  }

  func testRejectsMissingProductOversizedAndSymlinkedGraphs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = root.appendingPathComponent("configured-actions.json")
    try Data(Self.graphJSON.utf8).write(to: graph)

    XCTAssertThrowsError(
      try ConfiguredActionGraphValidator.validate(
        fileAt: graph,
        productPaths: ["bazel-out/sim/bin/App/Missing.app"],
        configurations: ["sim"]
      )
    ) { error in
      XCTAssertEqual(
        error as? ConfiguredActionGraphError,
        .missingProduct("bazel-out/sim/bin/App/Missing.app")
      )
    }

    XCTAssertThrowsError(
      try ConfiguredActionGraphValidator.validate(
        fileAt: graph,
        productPaths: ["bazel-out/sim/bin/App/App.app"],
        configurations: ["sim"],
        limits: ConfiguredActionGraphLimits(maximumFileBytes: 16)
      )
    ) { error in
      XCTAssertEqual(error as? ConfiguredActionGraphError, .fileLimitExceeded(16))
    }

    let linked = root.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: graph)
    XCTAssertThrowsError(
      try ConfiguredActionGraphValidator.validate(
        fileAt: linked,
        productPaths: ["bazel-out/sim/bin/App/App.app"],
        configurations: ["sim"]
      )
    ) { error in
      XCTAssertEqual(error as? ConfiguredActionGraphError, .unsafeFile(linked.path))
    }
  }

  func testRejectsDuplicateStructuralIdentifiersWithoutTrapping() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = root.appendingPathComponent("configured-actions.json")
    let duplicateGraph = Self.graphJSON.replacingOccurrences(
      of: #""artifacts": ["#,
      with: #""artifacts": [{"id":1,"pathFragmentId":5},"#
    )
    try Data(duplicateGraph.utf8).write(to: graph)

    XCTAssertThrowsError(
      try ConfiguredActionGraphValidator.validate(
        fileAt: graph,
        productPaths: ["bazel-out/sim/bin/App/App.app"],
        configurations: ["sim"]
      )
    ) { error in
      XCTAssertEqual(error as? ConfiguredActionGraphError, .invalidShape)
    }
  }

  private static let graphJSON = #"""
    {
      "actions": [
        {
          "configurationId": 1,
          "environmentVariables": [{"key":"TOKEN","value":"do-not-retain-action-graph-secret"}],
          "mnemonic": "SwiftCompile",
          "outputIds": [1],
          "primaryOutputId": 1,
          "targetId": 1
        },
        {
          "configurationId": 1,
          "inputDepSetIds": [10],
          "mnemonic": "BundleTreeApp",
          "outputIds": [2],
          "primaryOutputId": 2,
          "targetId": 2
        },
        {
          "configurationId": 2,
          "mnemonic": "ToolOnly",
          "outputIds": [3],
          "primaryOutputId": 3,
          "targetId": 3
        }
      ],
      "artifacts": [
        {"id":1,"pathFragmentId":5},
        {"id":2,"pathFragmentId":6},
        {"id":3,"pathFragmentId":7}
      ],
      "configuration": [
        {"id":1,"mnemonic":"sim"},
        {"id":2,"mnemonic":"darwin-opt-exec"}
      ],
      "depSetOfFiles": [
        {"id":10,"directArtifactIds":[1,3]}
      ],
      "pathFragments": [
        {"id":1,"label":"bazel-out"},
        {"id":2,"label":"sim","parentId":1},
        {"id":3,"label":"bin","parentId":2},
        {"id":4,"label":"App","parentId":3},
        {"id":5,"label":"App.swiftmodule","parentId":4},
        {"id":6,"label":"App.app","parentId":4},
        {"id":7,"label":"tool","parentId":3}
      ],
      "targets": [
        {"id":1,"label":"//app:App.library"},
        {"id":2,"label":"//app:App"},
        {"id":3,"label":"//tools:Tool"}
      ]
    }
    """#
}
