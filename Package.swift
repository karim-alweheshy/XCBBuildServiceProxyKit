// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "XCBBuildServiceProxyKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(
      name: "BazelProxyCore",
      targets: ["BazelProxyCore"]
    ),
    .executable(
      name: "ModernBuildServiceProxy",
      targets: ["ModernBuildServiceProxy"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/facebook/zstd.git",
      exact: "1.5.7"
    ),
    .package(
      url: "https://github.com/swiftlang/swift-build.git",
      revision: "e4f6fc77ebe727657dadfedf50462f5a1a626ead"
    ),
  ],
  targets: [
    .target(
      name: "BazelProxyCore",
      dependencies: [
        .product(name: "libzstd", package: "zstd")
      ],
      path: "Sources/BazelProxyCore"
    ),
    .target(
      name: "ModernBuildServiceProxyCore",
      path: "Sources/ModernBuildServiceProxyCore"
    ),
    .target(
      name: "ModernBuildServiceXcodeBridge",
      dependencies: [
        "BazelProxyCore",
        "ModernBuildServiceProxyCore",
        .product(name: "SWBProtocol", package: "swift-build"),
        .product(name: "SWBUtil", package: "swift-build"),
      ],
      path: "Sources/ModernBuildServiceXcodeBridge"
    ),
    .executableTarget(
      name: "ModernBuildServiceProxy",
      dependencies: ["ModernBuildServiceProxyCore", "ModernBuildServiceXcodeBridge"],
      path: "Sources/ModernBuildServiceProxy"
    ),
    .testTarget(
      name: "ModernBuildServiceProxyCoreTests",
      dependencies: ["ModernBuildServiceProxyCore"],
      path: "Tests/ModernBuildServiceProxyCoreTests"
    ),
    .testTarget(
      name: "ModernBuildServiceXcodeBridgeTests",
      dependencies: [
        "BazelProxyCore",
        "ModernBuildServiceXcodeBridge",
        .product(name: "SWBProtocol", package: "swift-build"),
        .product(name: "SWBUtil", package: "swift-build"),
      ],
      path: "Tests/ModernBuildServiceXcodeBridgeTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "BazelProxyCoreTests",
      dependencies: [
        "BazelProxyCore",
        .product(name: "libzstd", package: "zstd"),
      ],
      path: "Tests/BazelProxyCoreTests",
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v5]
)
