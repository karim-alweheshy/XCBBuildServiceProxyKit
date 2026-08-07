import Foundation

public struct MaterializedProductReceipt: Equatable, Sendable {
  public let destinationURL: URL
  public let itemCount: Int
  public let materialization: BuildProxyManifest.Product.Materialization
  public let replacedExistingProduct: Bool
  public let sourceURL: URL
  public let targetID: String
}

public struct ProductReceipt: Equatable, Sendable {
  public let products: [MaterializedProductReceipt]
}

public struct CleanReceipt: Equatable, Sendable {
  public let absentDestinations: [URL]
  public let removedDestinations: [URL]
}

public enum ProductMaterializationError: LocalizedError, Equatable, Sendable {
  case duplicateDestination(String)
  case invalidProduct(String)
  case missingDestination(String)
  case missingSource(String)
  case rollbackFailed(original: String, rollback: String)
  case symbolicLinkEscape(String)
  case transactionFailed(String)
  case unsafeDestination(String)
  case unsafeSource(String)
  case wrongProductType(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateDestination(let path):
      return "More than one resolved product uses destination \(path)."
    case .invalidProduct(let description):
      return "The resolved product is invalid: \(description)"
    case .missingDestination(let targetID):
      return "Resolved target \(targetID) has no destination product URL."
    case .missingSource(let targetID):
      return "Resolved target \(targetID) has no source product URL."
    case .rollbackFailed(let original, let rollback):
      return "Product transaction failed (\(original)) and rollback failed (\(rollback))."
    case .symbolicLinkEscape(let path):
      return "Product contains a symbolic link that escapes or cannot be validated: \(path)"
    case .transactionFailed(let description):
      return "Product transaction failed: \(description)"
    case .unsafeDestination(let path):
      return "Refusing to mutate unsafe product destination \(path)."
    case .unsafeSource(let path):
      return "Refusing to copy unsafe product source \(path)."
    case .wrongProductType(let path):
      return "Product does not match the manifest materialization type at \(path)."
    }
  }
}

enum ProductMutationPoint: Equatable, Sendable {
  case beforeCleanMove(index: Int, destination: URL)
  case beforeCleanCommitBarrier
  case beforeMaterializationCommitBarrier
  case beforeMaterializationCommit(index: Int, destination: URL)
}

enum ProductMutationCancellationError: Error, Equatable {
  case cancelledBeforeCommit
}

/// Linearizes cancellation against the first externally visible product mutation.
final class ProductMutationCancellationGate: @unchecked Sendable {
  private enum State: Equatable {
    case cancelled
    case committed
    case open
  }

  private let lock = NSLock()
  private var state = State.open

  func requestCancellation() {
    lock.withLock {
      if state == .open { state = .cancelled }
    }
  }

  func checkBeforeCommit() throws {
    try lock.withLock {
      if state == .cancelled {
        throw ProductMutationCancellationError.cancelledBeforeCommit
      }
    }
  }

  func beginCommit() throws {
    try lock.withLock {
      switch state {
      case .cancelled:
        throw ProductMutationCancellationError.cancelledBeforeCommit
      case .open:
        state = .committed
      case .committed:
        break
      }
    }
  }
}

public final class ProductMaterializer: @unchecked Sendable {
  private struct MaterializationEntry {
    var backupURL: URL?
    var committed = false
    let destinationURL: URL
    let itemCount: Int
    let mapping: BuildProxyManifest.Target
    let replacedExistingProduct: Bool
    let sourceURL: URL
    let stagedURL: URL
  }

  private struct CleanEntry {
    let destinationURL: URL
    let trashURL: URL
  }

  private static let mutationLock = NSLock()
  private let failureInjector: (@Sendable (ProductMutationPoint) -> (any Error)?)?

  public init() {
    failureInjector = nil
  }

  init(failureInjector: @escaping @Sendable (ProductMutationPoint) -> (any Error)?) {
    self.failureInjector = failureInjector
  }

  public func materialize(
    plan: ResolvedBuildPlan,
    fileManager: FileManager = .default
  ) throws -> ProductReceipt {
    try materialize(plan: plan, fileManager: fileManager, cancellationGate: nil)
  }

  func materialize(
    plan: ResolvedBuildPlan,
    fileManager: FileManager = .default,
    cancellationGate: ProductMutationCancellationGate?
  ) throws -> ProductReceipt {
    try Self.mutationLock.withLock {
      try materializeUnlocked(
        plan: plan,
        fileManager: fileManager,
        cancellationGate: cancellationGate
      )
    }
  }

  public func clean(
    plan: ResolvedBuildPlan,
    fileManager: FileManager = .default
  ) throws -> CleanReceipt {
    try clean(plan: plan, fileManager: fileManager, cancellationGate: nil)
  }

  func clean(
    plan: ResolvedBuildPlan,
    fileManager: FileManager = .default,
    cancellationGate: ProductMutationCancellationGate?
  ) throws -> CleanReceipt {
    try Self.mutationLock.withLock {
      try cleanUnlocked(
        plan: plan,
        fileManager: fileManager,
        cancellationGate: cancellationGate
      )
    }
  }

  private func materializeUnlocked(
    plan: ResolvedBuildPlan,
    fileManager: FileManager,
    cancellationGate: ProductMutationCancellationGate?
  ) throws -> ProductReceipt {
    var entries = [MaterializationEntry]()
    defer { removeTransactionArtifacts(entries: entries, fileManager: fileManager) }

    var destinations = Set<String>()
    for target in plan.targets {
      try cancellationGate?.checkBeforeCommit()
      guard target.mapping.product.materialization != .none else { continue }
      guard let paths = target.productPaths else {
        throw ProductMaterializationError.missingSource(target.mapping.targetID)
      }
      let source = try validatedSource(
        paths,
        mapping: target.mapping,
        fileManager: fileManager
      )
      let destination = try validatedDestination(
        paths,
        mapping: target.mapping,
        plan: plan,
        fileManager: fileManager
      )
      guard destinations.insert(destination.path).inserted else {
        throw ProductMaterializationError.duplicateDestination(destination.path)
      }
      guard source != destination else {
        throw ProductMaterializationError.unsafeDestination(destination.path)
      }

      let parent = destination.deletingLastPathComponent()
      try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
      let physicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
      guard physicalParent == parent else {
        throw ProductMaterializationError.unsafeDestination(parent.path)
      }
      let staged = parent.appendingPathComponent(
        ".bazel-proxy-stage-\(UUID().uuidString)-\(destination.lastPathComponent)"
      )
      guard !fileManager.fileExists(atPath: staged.path) else {
        throw ProductMaterializationError.transactionFailed("staging path already exists")
      }
      do {
        try fileManager.copyItem(at: source, to: staged)
        try cancellationGate?.checkBeforeCommit()
        try Self.validateProductType(
          staged,
          materialization: target.mapping.product.materialization,
          fileManager: fileManager
        )
        try Self.validateContainedSymbolicLinks(in: staged, fileManager: fileManager)
        entries.append(
          MaterializationEntry(
            backupURL: nil,
            destinationURL: destination,
            itemCount: try Self.itemCount(at: staged, fileManager: fileManager),
            mapping: target.mapping,
            replacedExistingProduct: fileManager.fileExists(atPath: destination.path),
            sourceURL: source,
            stagedURL: staged
          )
        )
      } catch {
        Self.makeTreeRemovable(staged, fileManager: fileManager)
        try? fileManager.removeItem(at: staged)
        throw error
      }
    }

    do {
      if let injected = failureInjector?(.beforeMaterializationCommitBarrier) {
        throw injected
      }
      try cancellationGate?.beginCommit()
      for index in entries.indices {
        if let injected = failureInjector?(
          .beforeMaterializationCommit(
            index: index,
            destination: entries[index].destinationURL
          )
        ) {
          throw injected
        }
        let destination = entries[index].destinationURL
        if fileManager.fileExists(atPath: destination.path) {
          try rejectSymbolicLink(destination, fileManager: fileManager)
          let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".bazel-proxy-backup-\(UUID().uuidString)-\(destination.lastPathComponent)"
          )
          try fileManager.moveItem(at: destination, to: backup)
          entries[index].backupURL = backup
        }
        try fileManager.moveItem(at: entries[index].stagedURL, to: destination)
        entries[index].committed = true
      }
    } catch let cancellation as ProductMutationCancellationError {
      do {
        try rollbackMaterialization(entries: entries, fileManager: fileManager)
      } catch let rollbackError {
        throw ProductMaterializationError.rollbackFailed(
          original: cancellation.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      throw cancellation
    } catch {
      do {
        try rollbackMaterialization(entries: entries, fileManager: fileManager)
      } catch let rollbackError {
        throw ProductMaterializationError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      throw ProductMaterializationError.transactionFailed(error.localizedDescription)
    }

    return ProductReceipt(
      products: entries.map {
        MaterializedProductReceipt(
          destinationURL: $0.destinationURL,
          itemCount: $0.itemCount,
          materialization: $0.mapping.product.materialization,
          replacedExistingProduct: $0.replacedExistingProduct,
          sourceURL: $0.sourceURL,
          targetID: $0.mapping.targetID
        )
      }
    )
  }

  private func cleanUnlocked(
    plan: ResolvedBuildPlan,
    fileManager: FileManager,
    cancellationGate: ProductMutationCancellationGate?
  ) throws -> CleanReceipt {
    var destinations = Set<String>()
    var absent = [URL]()
    var moved = [CleanEntry]()
    var validatedDestinations = [URL]()

    for target in plan.targets {
      guard target.mapping.product.materialization != .none else { continue }
      guard let paths = target.productPaths else {
        throw ProductMaterializationError.missingDestination(target.mapping.targetID)
      }
      let destination = try validatedDestination(
        paths,
        mapping: target.mapping,
        plan: plan,
        fileManager: fileManager
      )
      guard destinations.insert(destination.path).inserted else {
        throw ProductMaterializationError.duplicateDestination(destination.path)
      }
      validatedDestinations.append(destination)
    }

    do {
      try cancellationGate?.checkBeforeCommit()
      if let injected = failureInjector?(.beforeCleanCommitBarrier) {
        throw injected
      }
      try cancellationGate?.beginCommit()
      for destination in validatedDestinations {
        guard fileManager.fileExists(atPath: destination.path) else {
          absent.append(destination)
          continue
        }
        try rejectSymbolicLink(destination, fileManager: fileManager)
        if let injected = failureInjector?(
          .beforeCleanMove(index: moved.count, destination: destination)
        ) {
          throw injected
        }
        let trash = destination.deletingLastPathComponent().appendingPathComponent(
          ".bazel-proxy-clean-\(UUID().uuidString)-\(destination.lastPathComponent)"
        )
        try fileManager.moveItem(at: destination, to: trash)
        moved.append(CleanEntry(destinationURL: destination, trashURL: trash))
      }
    } catch let cancellation as ProductMutationCancellationError {
      do {
        for entry in moved.reversed() {
          try fileManager.moveItem(at: entry.trashURL, to: entry.destinationURL)
        }
      } catch let rollbackError {
        throw ProductMaterializationError.rollbackFailed(
          original: cancellation.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      throw cancellation
    } catch {
      do {
        for entry in moved.reversed() {
          try fileManager.moveItem(at: entry.trashURL, to: entry.destinationURL)
        }
      } catch let rollbackError {
        throw ProductMaterializationError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      throw ProductMaterializationError.transactionFailed(error.localizedDescription)
    }

    for entry in moved {
      Self.makeTreeRemovable(entry.trashURL, fileManager: fileManager)
      try? fileManager.removeItem(at: entry.trashURL)
    }
    return CleanReceipt(
      absentDestinations: absent.sorted { $0.path < $1.path },
      removedDestinations: moved.map(\.destinationURL).sorted { $0.path < $1.path }
    )
  }

  private func validatedSource(
    _ paths: ResolvedProductPaths,
    mapping: BuildProxyManifest.Target,
    fileManager: FileManager
  ) throws -> URL {
    let sourceURL = paths.sourceProductURL
    let rootURL = paths.bazelOutputRootURL
    guard sourceURL.isFileURL, sourceURL.path.hasPrefix("/"),
      rootURL.isFileURL, rootURL.path.hasPrefix("/"),
      paths.fullProductName == mapping.product.basename,
      !BuildProxySecurity.hasControlCharacters(sourceURL.path),
      !BuildProxySecurity.hasControlCharacters(rootURL.path),
      let manifestPath = mapping.product.path,
      manifestPath.hasPrefix("bazel-out/")
    else {
      throw ProductMaterializationError.unsafeSource(sourceURL.absoluteString)
    }

    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    try validateDirectoryRoot(root, error: .unsafeSource(root.path), fileManager: fileManager)
    let suffix = String(manifestPath.dropFirst("bazel-out/".count))
    let expected = root.appendingPathComponent(suffix).standardizedFileURL
    let lexical = sourceURL.standardizedFileURL
    try rejectSymbolicLink(lexical, fileManager: fileManager)
    let source = lexical.resolvingSymlinksInPath().standardizedFileURL
    guard source == expected,
      BuildProxySecurity.relativeDescendantPath(child: source, parent: root) != nil,
      source.lastPathComponent == mapping.product.basename,
      fileManager.fileExists(atPath: source.path)
    else {
      throw ProductMaterializationError.unsafeSource(source.path)
    }
    try Self.validateProductType(
      source,
      materialization: mapping.product.materialization,
      fileManager: fileManager
    )
    try Self.validateContainedSymbolicLinks(in: source, fileManager: fileManager)
    return source
  }

  private func validatedDestination(
    _ paths: ResolvedProductPaths,
    mapping: BuildProxyManifest.Target,
    plan: ResolvedBuildPlan,
    fileManager: FileManager
  ) throws -> URL {
    let destinationURL = paths.destinationProductURL
    let rootURL = paths.targetBuildDirectoryURL
    guard destinationURL.isFileURL, destinationURL.path.hasPrefix("/"),
      rootURL.isFileURL, rootURL.path.hasPrefix("/"),
      paths.fullProductName == mapping.product.basename,
      !paths.fullProductName.contains("/"),
      !BuildProxySecurity.hasControlCharacters(destinationURL.path),
      !BuildProxySecurity.hasControlCharacters(rootURL.path)
    else {
      throw ProductMaterializationError.unsafeDestination(destinationURL.absoluteString)
    }
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let forbiddenRoots = [
      URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL,
      FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        .standardizedFileURL,
      plan.intent.projectContainerURL.resolvingSymlinksInPath().standardizedFileURL,
      plan.intent.workspaceURL.resolvingSymlinksInPath().standardizedFileURL,
    ]
    guard !forbiddenRoots.contains(root) else {
      throw ProductMaterializationError.unsafeDestination(root.path)
    }
    try validateDirectoryRoot(root, error: .unsafeDestination(root.path), fileManager: fileManager)

    let lexical = destinationURL.standardizedFileURL
    if fileManager.fileExists(atPath: lexical.path) {
      try rejectSymbolicLink(lexical, fileManager: fileManager)
    }
    let destination = lexical.resolvingSymlinksInPath().standardizedFileURL
    let expected = root.appendingPathComponent(paths.fullProductName).standardizedFileURL
    guard destination == expected,
      destination.deletingLastPathComponent() == root,
      destination.lastPathComponent == mapping.product.basename
    else {
      throw ProductMaterializationError.unsafeDestination(destination.path)
    }
    return destination
  }

  private func validateDirectoryRoot(
    _ url: URL,
    error: ProductMaterializationError,
    fileManager: FileManager
  ) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw error
    }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw error }
  }

  private func rejectSymbolicLink(_ url: URL, fileManager: FileManager) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw ProductMaterializationError.invalidProduct(error.localizedDescription)
    }
    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
      throw ProductMaterializationError.symbolicLinkEscape(url.path)
    }
  }

  private func rollbackMaterialization(
    entries: [MaterializationEntry],
    fileManager: FileManager
  ) throws {
    for entry in entries.reversed() {
      if entry.committed, fileManager.fileExists(atPath: entry.destinationURL.path) {
        Self.makeTreeRemovable(entry.destinationURL, fileManager: fileManager)
        try fileManager.removeItem(at: entry.destinationURL)
      }
      if let backupURL = entry.backupURL,
        fileManager.fileExists(atPath: backupURL.path),
        !fileManager.fileExists(atPath: entry.destinationURL.path)
      {
        try fileManager.moveItem(at: backupURL, to: entry.destinationURL)
      }
    }
  }

  private func removeTransactionArtifacts(
    entries: [MaterializationEntry],
    fileManager: FileManager
  ) {
    for entry in entries {
      for url in [entry.stagedURL, entry.backupURL].compactMap({ $0 }) {
        Self.makeTreeRemovable(url, fileManager: fileManager)
        try? fileManager.removeItem(at: url)
      }
    }
  }

  private static func validateProductType(
    _ url: URL,
    materialization: BuildProxyManifest.Product.Materialization,
    fileManager: FileManager
  ) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let type = attributes[.type] as? FileAttributeType
    switch materialization {
    case .copyTree where type != .typeDirectory:
      throw ProductMaterializationError.wrongProductType(url.path)
    case .copyFile where type != .typeRegular:
      throw ProductMaterializationError.wrongProductType(url.path)
    case .copyFile, .copyTree:
      break
    case .none:
      throw ProductMaterializationError.invalidProduct(
        "a non-materialized product entered the copy transaction"
      )
    }
  }

  private static func validateContainedSymbolicLinks(
    in root: URL,
    fileManager: FileManager
  ) throws {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      )
    else {
      return
    }
    for case let url as URL in enumerator {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
      let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
      guard !destination.hasPrefix("/") else {
        throw ProductMaterializationError.symbolicLinkEscape(url.path)
      }
      let target = url.deletingLastPathComponent()
        .appendingPathComponent(destination)
        .standardizedFileURL
      guard fileManager.fileExists(atPath: target.path) else {
        throw ProductMaterializationError.symbolicLinkEscape(url.path)
      }
      let physicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
      guard
        physicalTarget == root
          || BuildProxySecurity.relativeDescendantPath(
            child: physicalTarget,
            parent: root
          ) != nil
      else {
        throw ProductMaterializationError.symbolicLinkEscape(url.path)
      }
    }
  }

  private static func makeTreeRemovable(_ root: URL, fileManager: FileManager) {
    if let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: nil,
      options: [],
      errorHandler: { _, _ in true }
    ) {
      for case let url as URL in enumerator {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType != .typeSymbolicLink {
          try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
      }
    }
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  }

  private static func itemCount(at root: URL, fileManager: FileManager) throws -> Int {
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      return 1
    }
    var count = 1
    for _ in enumerator {
      count += 1
    }
    return count
  }
}
