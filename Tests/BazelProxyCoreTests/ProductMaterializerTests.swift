import Foundation
import XCTest

@testable import BazelProxyCore

final class ProductMaterializerTests: XCTestCase {
  func testMaterializesAndCleansOnlyResolvedProductTransactionally() throws {
    let fixture = try ManifestFixture()
    let source = fixture.workspaceURL.appendingPathComponent(
      "bazel-out/products/App.app",
      isDirectory: true
    )
    let resource = source.appendingPathComponent("resource")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("new-product".utf8).write(to: resource)
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("resource-link").path,
      withDestinationPath: "resource"
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: source.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: resource.path)

    let destination = fixture.rootURL.appendingPathComponent(
      "DerivedProducts/App.app",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("old-product".utf8).write(to: destination.appendingPathComponent("old"))
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])

    let receipt = try ProductMaterializer().materialize(plan: plan)

    XCTAssertEqual(receipt.products.count, 1)
    XCTAssertTrue(receipt.products[0].replacedExistingProduct)
    XCTAssertEqual(
      try String(contentsOf: destination.appendingPathComponent("resource"), encoding: .utf8),
      "new-product"
    )
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: destination.appendingPathComponent("resource-link").path
      ),
      "resource"
    )
    XCTAssertEqual(try permissions(destination), try permissions(source))
    XCTAssertEqual(
      try permissions(destination.appendingPathComponent("resource")),
      try permissions(source.appendingPathComponent("resource"))
    )

    let cleanReceipt = try ProductMaterializer().clean(plan: plan)
    XCTAssertEqual(cleanReceipt.removedDestinations, [destination])
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testRollsBackAllPublishedProductsWhenSecondCommitFails() throws {
    let fixture = try ManifestFixture()
    var manifestObject = fixture.baseManifest()
    manifestObject["targets"] = [
      fixture.baseTarget(),
      fixture.baseTarget(
        bazelLabel: "//lib:Library",
        productBasename: "Library.framework",
        productName: "Library",
        productType: "com.apple.product-type.framework",
        targetID: "lib-library",
        xcodeTargetGUID: "LIB_GUID"
      ),
    ]
    try fixture.writeManifest(manifestObject)

    let sourceApp = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "new-app"
    )
    let sourceLibrary = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/Library.framework"),
      contents: "new-library"
    )
    let destinationApp = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "old-app"
    )
    let destinationLibrary = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/Library.framework"),
      contents: "old-library"
    )
    let plan = try makePlan(
      fixture: fixture,
      products: [
        (sourceApp, destinationApp),
        (sourceLibrary, destinationLibrary),
      ]
    )
    let materializer = ProductMaterializer { point in
      if case .beforeMaterializationCommit(index: 1, destination: _) = point {
        return FixtureError.creationFailed("injected second commit failure")
      }
      return nil
    }

    XCTAssertThrowsError(try materializer.materialize(plan: plan))
    XCTAssertEqual(try productContents(destinationApp), "old-app")
    XCTAssertEqual(try productContents(destinationLibrary), "old-library")
    XCTAssertEqual(try transactionArtifacts(in: destinationApp.deletingLastPathComponent()), [])
  }

  func testRollsBackCleanWhenSecondDestinationMoveFails() throws {
    let fixture = try ManifestFixture()
    var manifestObject = fixture.baseManifest()
    manifestObject["targets"] = [
      fixture.baseTarget(),
      fixture.baseTarget(
        bazelLabel: "//lib:Library",
        productBasename: "Library.framework",
        productName: "Library",
        productType: "com.apple.product-type.framework",
        targetID: "lib-library",
        xcodeTargetGUID: "LIB_GUID"
      ),
    ]
    try fixture.writeManifest(manifestObject)
    let sourceApp = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "source-app"
    )
    let sourceLibrary = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/Library.framework"),
      contents: "source-library"
    )
    let destinationApp = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "existing-app"
    )
    let destinationLibrary = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/Library.framework"),
      contents: "existing-library"
    )
    let plan = try makePlan(
      fixture: fixture,
      products: [
        (sourceApp, destinationApp),
        (sourceLibrary, destinationLibrary),
      ]
    )
    let materializer = ProductMaterializer { point in
      if case .beforeCleanMove(index: 1, destination: _) = point {
        return FixtureError.creationFailed("injected clean failure")
      }
      return nil
    }

    XCTAssertThrowsError(try materializer.clean(plan: plan))
    XCTAssertEqual(try productContents(destinationApp), "existing-app")
    XCTAssertEqual(try productContents(destinationLibrary), "existing-library")
  }

  func testCancellationBeforeMaterializationCommitLeavesExistingProductUntouched() async throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "new"
    )
    let destination = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "old"
    )
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])
    let barrierReached = DispatchSemaphore(value: 0)
    let releaseBarrier = DispatchSemaphore(value: 0)
    let materializer = ProductMaterializer { point in
      if point == .beforeMaterializationCommitBarrier {
        barrierReached.signal()
        releaseBarrier.wait()
      }
      return nil
    }
    let gate = ProductMutationCancellationGate()

    let task = Task.detached {
      try materializer.materialize(plan: plan, cancellationGate: gate)
    }
    XCTAssertEqual(barrierReached.wait(timeout: .now() + 2), .success)
    gate.requestCancellation()
    releaseBarrier.signal()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation before commit")
    } catch {
      XCTAssertEqual(error as? ProductMutationCancellationError, .cancelledBeforeCommit)
    }
    XCTAssertEqual(try productContents(destination), "old")
    XCTAssertEqual(try transactionArtifacts(in: destination.deletingLastPathComponent()), [])
  }

  func testCancellationAfterMaterializationCommitBarrierCannotReportCancelledProduct() async throws
  {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "new"
    )
    let destination = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "old"
    )
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])
    let commitAccepted = DispatchSemaphore(value: 0)
    let releaseCommit = DispatchSemaphore(value: 0)
    let materializer = ProductMaterializer { point in
      if case .beforeMaterializationCommit(index: 0, destination: _) = point {
        commitAccepted.signal()
        releaseCommit.wait()
      }
      return nil
    }
    let gate = ProductMutationCancellationGate()

    let task = Task.detached {
      try materializer.materialize(plan: plan, cancellationGate: gate)
    }
    XCTAssertEqual(commitAccepted.wait(timeout: .now() + 2), .success)
    gate.requestCancellation()
    releaseCommit.signal()
    let receipt = try await task.value
    XCTAssertEqual(receipt.products.map(\.targetID), ["app-app"])
    XCTAssertEqual(try productContents(destination), "new")
  }

  func testCancellationBeforeCleanCommitLeavesProductUntouched() async throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "source"
    )
    let destination = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "existing"
    )
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])
    let barrierReached = DispatchSemaphore(value: 0)
    let releaseBarrier = DispatchSemaphore(value: 0)
    let materializer = ProductMaterializer { point in
      if point == .beforeCleanCommitBarrier {
        barrierReached.signal()
        releaseBarrier.wait()
      }
      return nil
    }
    let gate = ProductMutationCancellationGate()

    let task = Task.detached {
      try materializer.clean(plan: plan, cancellationGate: gate)
    }
    XCTAssertEqual(barrierReached.wait(timeout: .now() + 2), .success)
    gate.requestCancellation()
    releaseBarrier.signal()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation before clean commit")
    } catch {
      XCTAssertEqual(error as? ProductMutationCancellationError, .cancelledBeforeCommit)
    }
    XCTAssertEqual(try productContents(destination), "existing")
  }

  func testRejectsEscapingSourceSymlinkAndDestinationSymlink() throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "source"
    )
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("escape").path,
      withDestinationPath: "/tmp"
    )
    let destination = fixture.rootURL.appendingPathComponent("products/App.app")
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])
    XCTAssertThrowsError(try ProductMaterializer().materialize(plan: plan)) { error in
      guard case .symbolicLinkEscape = error as? ProductMaterializationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
    let outside = try createProduct(
      at: fixture.rootURL.appendingPathComponent("outside/App.app"),
      contents: "outside"
    )
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
    XCTAssertThrowsError(try ProductMaterializer().materialize(plan: plan)) { error in
      guard case .symbolicLinkEscape = error as? ProductMaterializationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsFileTreeMismatchWithoutChangingDestination() throws {
    let fixture = try ManifestFixture()
    let source = fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not-a-tree".utf8).write(to: source)
    let destination = try createProduct(
      at: fixture.rootURL.appendingPathComponent("products/App.app"),
      contents: "old"
    )
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])

    XCTAssertThrowsError(try ProductMaterializer().materialize(plan: plan)) { error in
      XCTAssertEqual(error as? ProductMaterializationError, .wrongProductType(source.path))
    }
    XCTAssertEqual(try productContents(destination), "old")
  }

  func testRejectsSourceOutsideDeclaredBazelOutputRoot() throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("untrusted/App.app"),
      contents: "untrusted"
    )
    try FileManager.default.createDirectory(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out"),
      withIntermediateDirectories: true
    )
    let destinationRoot = fixture.rootURL.appendingPathComponent("products")
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let destination = destinationRoot.appendingPathComponent("App.app")
    let plan = try makePlan(fixture: fixture, products: [(source, destination)])

    XCTAssertThrowsError(try ProductMaterializer().materialize(plan: plan)) { error in
      guard case .unsafeSource = error as? ProductMaterializationError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testRejectsDestinationOutsideDeclaredTargetBuildDirectoryForMaterializeAndClean() throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "source"
    )
    let safeRoot = fixture.rootURL.appendingPathComponent("safe-products")
    let outsideRoot = fixture.rootURL.appendingPathComponent("outside-products")
    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
    let outside = try createProduct(
      at: outsideRoot.appendingPathComponent("App.app"),
      contents: "must-survive"
    )
    let base = try makePlan(fixture: fixture, products: [(source, outside)])
    let plan = replacingProductPaths(
      in: base,
      with: ResolvedProductPaths(
        bazelOutputRootURL: fixture.workspaceURL.appendingPathComponent("bazel-out"),
        destinationProductURL: outside,
        fullProductName: "App.app",
        sourceProductURL: source,
        targetBuildDirectoryURL: safeRoot
      )
    )

    for operation in [
      { try ProductMaterializer().materialize(plan: plan) as Any },
      { try ProductMaterializer().clean(plan: plan) as Any },
    ] {
      XCTAssertThrowsError(try operation()) { error in
        guard case .unsafeDestination = error as? ProductMaterializationError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
    XCTAssertEqual(try productContents(outside), "must-survive")
  }

  func testRejectsRootHomeProjectAndWorkspaceAsDestinationMutationRoots() throws {
    let fixture = try ManifestFixture()
    let source = try createProduct(
      at: fixture.workspaceURL.appendingPathComponent("bazel-out/products/App.app"),
      contents: "source"
    )
    for root in [
      URL(fileURLWithPath: "/", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser,
      fixture.projectURL,
      fixture.workspaceURL,
    ] {
      let destination = root.appendingPathComponent("App.app")
      let base = try makePlan(fixture: fixture, products: [(source, destination)])
      let plan = replacingProductPaths(
        in: base,
        with: ResolvedProductPaths(
          bazelOutputRootURL: fixture.workspaceURL.appendingPathComponent("bazel-out"),
          destinationProductURL: destination,
          fullProductName: "App.app",
          sourceProductURL: source,
          targetBuildDirectoryURL: root
        )
      )

      XCTAssertThrowsError(try ProductMaterializer().clean(plan: plan)) { error in
        guard case .unsafeDestination = error as? ProductMaterializationError else {
          return XCTFail("Unexpected error for \(root.path): \(error)")
        }
      }
    }
  }

  private func makePlan(
    fixture: ManifestFixture,
    products: [(source: URL, destination: URL)]
  ) throws -> ResolvedBuildPlan {
    let manifest = try fixture.load()
    XCTAssertEqual(manifest.targets.count, products.count)
    let targetPlans = zip(manifest.targets, products).map { mapping, product in
      ResolvedTargetPlan(
        mapping: mapping,
        productPaths: ResolvedProductPaths(
          bazelOutputRootURL: fixture.workspaceURL.appendingPathComponent("bazel-out"),
          destinationProductURL: product.destination,
          fullProductName: mapping.product.basename,
          sourceProductURL: product.source,
          targetBuildDirectoryURL: product.destination.deletingLastPathComponent()
        )
      )
    }
    return ResolvedBuildPlan(
      adapterRequest: AdapterRequest(
        labels: manifest.targets.map(\.bazelLabel),
        outputGroups: manifest.targets.map(\.outputGroup),
        targetIDs: manifest.targets.map(\.targetID)
      ),
      evaluatedEnvironment: ["ACTION": "build"],
      intent: fixture.intent(),
      manifest: manifest,
      manifestURL: fixture.manifestURL,
      operationID: UUID().uuidString,
      targets: targetPlans
    )
  }

  private func createProduct(at url: URL, contents: String) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url.appendingPathComponent("contents"))
    return url
  }

  private func replacingProductPaths(
    in plan: ResolvedBuildPlan,
    with productPaths: ResolvedProductPaths
  ) -> ResolvedBuildPlan {
    ResolvedBuildPlan(
      adapterRequest: plan.adapterRequest,
      evaluatedEnvironment: plan.evaluatedEnvironment,
      intent: plan.intent,
      manifest: plan.manifest,
      manifestURL: plan.manifestURL,
      operationID: plan.operationID,
      targets: [ResolvedTargetPlan(mapping: plan.targets[0].mapping, productPaths: productPaths)]
    )
  }

  private func productContents(_ url: URL) throws -> String {
    try String(contentsOf: url.appendingPathComponent("contents"), encoding: .utf8)
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  private func transactionArtifacts(in parent: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
      $0.hasPrefix(".bazel-proxy-")
    }.sorted()
  }
}
