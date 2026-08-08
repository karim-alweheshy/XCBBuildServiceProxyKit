import Foundation

public struct NativeBuildServiceResolution: Equatable {
  public let xcodeURL: URL
  public let developerURL: URL
  public let serviceExecutableURL: URL
  public let productBuildVersion: String

  public init(
    xcodeURL: URL,
    developerURL: URL,
    serviceExecutableURL: URL,
    productBuildVersion: String
  ) {
    self.xcodeURL = xcodeURL
    self.developerURL = developerURL
    self.serviceExecutableURL = serviceExecutableURL
    self.productBuildVersion = productBuildVersion
  }
}

public enum NativeBuildServiceResolverError: LocalizedError, Equatable {
  case missingDeveloperDirectory
  case invalidXcodePath(String)
  case unreadableVersionPlist(String)
  case unsupportedXcodeBuild(expected: String, actual: String)
  case missingNativeService(String)
  case recursiveServiceSelection(String)

  public var errorDescription: String? {
    switch self {
    case .missingDeveloperDirectory:
      return "No selected Xcode could be resolved. Set DEVELOPER_DIR or XCBPROXY_XCODE_PATH."
    case .invalidXcodePath(let path):
      return "The selected developer directory is not inside an Xcode application: \(path)"
    case .unreadableVersionPlist(let path):
      return "The selected Xcode version metadata is unreadable: \(path)"
    case .unsupportedXcodeBuild(let expected, let actual):
      return "Unsupported Xcode build \(actual); this proxy supports exactly \(expected)."
    case .missingNativeService(let path):
      return "The selected Xcode native build service is missing or not executable: \(path)"
    case .recursiveServiceSelection(let path):
      return "The proxy resolved itself as the native build service: \(path)"
    }
  }
}

public enum NativeBuildServiceResolver {
  public static let supportedProductBuildVersion = "17F42"

  // Xcode 26.5's SwiftBuild client resolves its service from this bundle.
  public static let serviceRelativePath =
    "Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService"

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentExecutableURL: URL? = Bundle.main.executableURL
  ) throws -> NativeBuildServiceResolution {
    let selectedPath: String
    if let explicitPath = environment["XCBPROXY_XCODE_PATH"], !explicitPath.isEmpty {
      selectedPath = explicitPath
    } else if let developerDirectory = environment["DEVELOPER_DIR"], !developerDirectory.isEmpty {
      selectedPath = developerDirectory
    } else {
      selectedPath = try selectedDeveloperDirectory()
    }

    let xcodeURL = try resolveXcodeURL(from: URL(fileURLWithPath: selectedPath, isDirectory: true))
    let developerURL = xcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
    let versionPlistURL = xcodeURL.appendingPathComponent(
      "Contents/version.plist", isDirectory: false)
    let productBuildVersion = try readProductBuildVersion(at: versionPlistURL)

    guard productBuildVersion == supportedProductBuildVersion else {
      throw NativeBuildServiceResolverError.unsupportedXcodeBuild(
        expected: supportedProductBuildVersion,
        actual: productBuildVersion
      )
    }

    let serviceURL = xcodeURL.appendingPathComponent(serviceRelativePath, isDirectory: false)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: serviceURL.path) else {
      throw NativeBuildServiceResolverError.missingNativeService(serviceURL.path)
    }

    if let currentExecutableURL,
      currentExecutableURL.resolvingSymlinksInPath().standardizedFileURL == serviceURL
    {
      throw NativeBuildServiceResolverError.recursiveServiceSelection(serviceURL.path)
    }

    return NativeBuildServiceResolution(
      xcodeURL: xcodeURL,
      developerURL: developerURL,
      serviceExecutableURL: serviceURL,
      productBuildVersion: productBuildVersion
    )
  }

  public static func sanitizedChildEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment,
    developerURL: URL
  ) -> [String: String] {
    let allowedKeys = [
      "HOME",
      "LANG",
      "LC_ALL",
      "LOGNAME",
      "PATH",
      "SHELL",
      "TMPDIR",
      "USER",
    ]
    var result: [String: String] = [:]
    for key in allowedKeys {
      if let value = environment[key] {
        result[key] = value
      }
    }
    result["DEVELOPER_DIR"] = developerURL.path
    return result
  }

  private static func selectedDeveloperDirectory() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NativeBuildServiceResolverError.missingDeveloperDirectory
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard
      let value = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw NativeBuildServiceResolverError.missingDeveloperDirectory
    }
    return value
  }

  private static func resolveXcodeURL(from inputURL: URL) throws -> URL {
    var candidate = inputURL.resolvingSymlinksInPath().standardizedFileURL
    while candidate.path != "/" {
      if candidate.pathExtension == "app",
        candidate.lastPathComponent.lowercased().hasPrefix("xcode")
      {
        let developerURL = candidate.appendingPathComponent("Contents/Developer", isDirectory: true)
        guard FileManager.default.fileExists(atPath: developerURL.path) else {
          break
        }
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    throw NativeBuildServiceResolverError.invalidXcodePath(inputURL.path)
  }

  private static func readProductBuildVersion(at url: URL) throws -> String {
    do {
      let data = try Data(contentsOf: url)
      guard
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        let buildVersion = plist["ProductBuildVersion"] as? String,
        !buildVersion.isEmpty
      else {
        throw NativeBuildServiceResolverError.unreadableVersionPlist(url.path)
      }
      return buildVersion
    } catch let error as NativeBuildServiceResolverError {
      throw error
    } catch {
      throw NativeBuildServiceResolverError.unreadableVersionPlist(url.path)
    }
  }
}
