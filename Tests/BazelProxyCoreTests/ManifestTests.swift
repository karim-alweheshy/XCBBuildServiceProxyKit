import CryptoKit
import Foundation
import XCTest

@testable import BazelProxyCore

final class ManifestTests: XCTestCase {
  func testLoadsStrictSchemaV2Manifest() throws {
    let fixture = try ManifestFixture()
    let manifest = try fixture.load()

    XCTAssertEqual(manifest.schemaVersion, 2)
    XCTAssertEqual(manifest.project.containerName, "App.xcodeproj")
    XCTAssertEqual(manifest.targets.map(\.targetID), ["app-app"])
  }

  func testVerifiedLoadHashesTheExactDecodedSnapshot() throws {
    let fixture = try ManifestFixture()
    let data = try Data(contentsOf: fixture.manifestURL)
    let expectedSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

    let loaded = try BuildProxyManifest.loadVerified(
      from: fixture.manifestURL,
      expecting: BuildProxyManifestExpectation(
        projectContainerURL: fixture.projectURL,
        projectIdentity: "project-identity"
      ),
      expectedSHA256: expectedSHA256
    )

    XCTAssertEqual(loaded.manifest.schemaVersion, 2)
    XCTAssertEqual(loaded.fileIdentity.algorithm, "sha256")
    XCTAssertEqual(loaded.fileIdentity.byteSize, UInt64(data.count))
    XCTAssertEqual(loaded.fileIdentity.hex, expectedSHA256)
  }

  func testVerifiedLoadRejectsMalformedAndMismatchedSHA256() throws {
    let fixture = try ManifestFixture()
    let expectation = BuildProxyManifestExpectation(
      projectContainerURL: fixture.projectURL,
      projectIdentity: "project-identity"
    )

    XCTAssertThrowsError(
      try BuildProxyManifest.loadVerified(
        from: fixture.manifestURL,
        expecting: expectation,
        expectedSHA256: "ABC"
      )
    ) { error in
      XCTAssertEqual(error as? BuildProxyManifestError, .invalidExpectedSHA256("ABC"))
    }

    let wrongDigest = String(repeating: "0", count: 64)
    XCTAssertThrowsError(
      try BuildProxyManifest.loadVerified(
        from: fixture.manifestURL,
        expecting: expectation,
        expectedSHA256: wrongDigest
      )
    ) { error in
      guard
        case .sha256Mismatch(let expected, let actual) =
          error as? BuildProxyManifestError
      else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(expected, wrongDigest)
      XCTAssertEqual(actual.count, 64)
      XCTAssertNotEqual(actual, wrongDigest)
    }
  }

  func testRejectsUnknownJSONKey() throws {
    let fixture = try ManifestFixture()
    var object = fixture.baseManifest()
    object["futureField"] = true
    try fixture.writeManifest(object)

    XCTAssertThrowsError(try fixture.load()) { error in
      guard case .invalidShape(let description) = error as? BuildProxyManifestError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(description.contains("futureField"))
    }
  }

  func testRejectsUnsupportedSchema() throws {
    let fixture = try ManifestFixture()
    var object = fixture.baseManifest()
    object["schemaVersion"] = 3
    try fixture.writeManifest(object)

    XCTAssertThrowsError(try fixture.load()) { error in
      XCTAssertEqual(error as? BuildProxyManifestError, .unsupportedSchema(3))
    }
  }

  func testRejectsUnsafeAdapterAndProductPaths() throws {
    let fixture = try ManifestFixture()
    var adapterObject = fixture.baseManifest()
    var invocation = try mutableDictionary(adapterObject, key: "invocation")
    invocation["adapterPath"] = "../outside.sh"
    adapterObject["invocation"] = invocation
    try fixture.writeManifest(adapterObject)
    XCTAssertThrowsError(try fixture.load())

    var productObject = fixture.baseManifest()
    var targets = try XCTUnwrap(productObject["targets"] as? [[String: Any]])
    var product = try mutableDictionary(targets[0], key: "product")
    product["path"] = "bazel-out/../App.app"
    targets[0]["product"] = product
    productObject["targets"] = targets
    try fixture.writeManifest(productObject)
    XCTAssertThrowsError(try fixture.load())
  }

  func testRejectsWrongProjectIdentity() throws {
    let fixture = try ManifestFixture()
    XCTAssertThrowsError(try fixture.load(projectIdentity: "stale-identity")) { error in
      XCTAssertEqual(
        error as? BuildProxyManifestError,
        .projectIdentityMismatch(expected: "stale-identity", actual: "project-identity")
      )
    }
  }

  func testRejectsSensitiveEnvironmentKey() throws {
    let fixture = try ManifestFixture()
    var object = fixture.baseManifest()
    var invocation = try mutableDictionary(object, key: "invocation")
    invocation["environmentKeys"] = ["ACTION", "PRIVATE_AUTH_TOKEN"]
    object["invocation"] = invocation
    try fixture.writeManifest(object)

    XCTAssertThrowsError(try fixture.load()) { error in
      XCTAssertEqual(
        error as? BuildProxyManifestError,
        .sensitiveEnvironmentKey("PRIVATE_AUTH_TOKEN")
      )
    }
  }

  func testRejectsManifestSymlink() throws {
    let fixture = try ManifestFixture()
    let outsideURL = fixture.rootURL.appendingPathComponent("outside.json")
    try FileManager.default.copyItem(at: fixture.manifestURL, to: outsideURL)
    try FileManager.default.removeItem(at: fixture.manifestURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.manifestURL, withDestinationURL: outsideURL)

    XCTAssertThrowsError(try fixture.load()) { error in
      XCTAssertEqual(error as? BuildProxyManifestError, .symbolicLink(fixture.manifestURL.path))
    }
  }

  func testRejectsDuplicateMappingAndIgnoredGUIDCollision() throws {
    let fixture = try ManifestFixture()
    var duplicateObject = fixture.baseManifest()
    duplicateObject["targets"] = [fixture.baseTarget(), fixture.baseTarget()]
    try fixture.writeManifest(duplicateObject)
    XCTAssertThrowsError(try fixture.load())

    var collisionObject = fixture.baseManifest()
    collisionObject["ignoredXcodeTargetGUIDs"] = ["APP_GUID"]
    try fixture.writeManifest(collisionObject)
    XCTAssertThrowsError(try fixture.load())
  }
}
