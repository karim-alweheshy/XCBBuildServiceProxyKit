import Foundation
import XCTest

@testable import ModernBuildServiceProxyCore

final class NativeBuildServiceResolverTests: XCTestCase {
  func testResolvesPinnedServiceFromDeveloperDirectory() throws {
    let fixture = try XcodeFixture(buildVersion: "17F42")
    defer { fixture.remove() }

    let result = try NativeBuildServiceResolver.resolve(
      environment: ["DEVELOPER_DIR": fixture.developerURL.path],
      currentExecutableURL: URL(fileURLWithPath: "/tmp/proxy")
    )

    XCTAssertEqual(result.xcodeURL, fixture.xcodeURL)
    XCTAssertEqual(result.developerURL, fixture.developerURL)
    XCTAssertEqual(result.serviceExecutableURL, fixture.serviceURL)
    XCTAssertEqual(result.productBuildVersion, "17F42")
  }

  func testExplicitXcodePathTakesPrecedence() throws {
    let fixture = try XcodeFixture(buildVersion: "17F42")
    defer { fixture.remove() }

    let result = try NativeBuildServiceResolver.resolve(
      environment: [
        "XCBPROXY_XCODE_PATH": fixture.xcodeURL.path,
        "DEVELOPER_DIR": "/unsupported",
      ],
      currentExecutableURL: URL(fileURLWithPath: "/tmp/proxy")
    )

    XCTAssertEqual(result.serviceExecutableURL, fixture.serviceURL)
  }

  func testRejectsUnsupportedXcodeBeforeLaunch() throws {
    let fixture = try XcodeFixture(buildVersion: "17F41")
    defer { fixture.remove() }

    XCTAssertThrowsError(
      try NativeBuildServiceResolver.resolve(
        environment: ["DEVELOPER_DIR": fixture.developerURL.path],
        currentExecutableURL: URL(fileURLWithPath: "/tmp/proxy")
      )
    ) { error in
      XCTAssertEqual(
        error as? NativeBuildServiceResolverError,
        .unsupportedXcodeBuild(expected: "17F42", actual: "17F41")
      )
    }
  }

  func testSanitizedChildEnvironmentRemovesServiceOverrides() {
    let developerURL = URL(fileURLWithPath: "/Xcode.app/Contents/Developer")
    let result = NativeBuildServiceResolver.sanitizedChildEnvironment(
      [
        "XCBBUILDSERVICE_PATH": "proxy",
        "SWBBUILDSERVICE_PATH": "proxy",
        "XCBBUILDSERVICE_BUNDLE_PATH": "proxy",
        "SWBBUILDSERVICE_BUNDLE_PATH": "proxy",
        "XCBPROXY_XCODE_PATH": "/Xcode.app",
        "XCBPROXY_LOG_SUMMARY": "1",
        "SAFE_KEY": "preserved",
        "AUTH_TOKEN": "must-not-be-inherited",
      ],
      developerURL: developerURL
    )

    XCTAssertNil(result["XCBBUILDSERVICE_PATH"])
    XCTAssertNil(result["SWBBUILDSERVICE_PATH"])
    XCTAssertNil(result["XCBBUILDSERVICE_BUNDLE_PATH"])
    XCTAssertNil(result["SWBBUILDSERVICE_BUNDLE_PATH"])
    XCTAssertNil(result["XCBPROXY_XCODE_PATH"])
    XCTAssertNil(result["XCBPROXY_LOG_SUMMARY"])
    XCTAssertNil(result["SAFE_KEY"])
    XCTAssertNil(result["AUTH_TOKEN"])
    XCTAssertEqual(result["DEVELOPER_DIR"], developerURL.path)
  }
}

private final class XcodeFixture {
  let rootURL: URL
  let xcodeURL: URL
  let developerURL: URL
  let serviceURL: URL

  init(buildVersion: String) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    xcodeURL = rootURL.appendingPathComponent("Xcode-26.5.0.app", isDirectory: true)
    developerURL = xcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
    serviceURL = xcodeURL.appendingPathComponent(
      NativeBuildServiceResolver.serviceRelativePath,
      isDirectory: false
    )

    try FileManager.default.createDirectory(
      at: developerURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: serviceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let plist: [String: Any] = ["ProductBuildVersion": buildVersion]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: xcodeURL.appendingPathComponent("Contents/version.plist"))
    try Data("#!/bin/sh\n/bin/cat\n".utf8).write(to: serviceURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: serviceURL.path
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
