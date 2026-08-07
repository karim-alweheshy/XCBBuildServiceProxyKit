// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XCBBuildServiceProxyKit",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "ModernBuildServiceProxy",
      targets: ["ModernBuildServiceProxy"]
    )
  ],
  targets: [
    .target(
      name: "ModernBuildServiceProxyCore",
      path: "Sources/ModernBuildServiceProxyCore"
    ),
    .executableTarget(
      name: "ModernBuildServiceProxy",
      dependencies: ["ModernBuildServiceProxyCore"],
      path: "Sources/ModernBuildServiceProxy"
    ),
    .testTarget(
      name: "ModernBuildServiceProxyCoreTests",
      dependencies: ["ModernBuildServiceProxyCore"],
      path: "Tests/ModernBuildServiceProxyCoreTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
