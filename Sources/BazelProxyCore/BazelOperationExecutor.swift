import Foundation

public protocol AdapterInvocationPreparing: Sendable {
  func make(
    for plan: ResolvedBuildPlan,
    processEnvironment: [String: String]
  ) throws -> AdapterInvocation
}

extension AdapterInvocationFactory: AdapterInvocationPreparing {
  public func make(
    for plan: ResolvedBuildPlan,
    processEnvironment: [String: String]
  ) throws -> AdapterInvocation {
    try make(
      for: plan,
      processEnvironment: processEnvironment,
      fileManager: .default
    )
  }
}

public enum BazelOperationExecutionEvent: Equatable, Sendable {
  case bep(BEPEvent)
  case processOutput(ProcessOutputEvent)
}

public enum BazelOperationFailurePhase: String, Equatable, Sendable {
  case bepValidation
  case clean
  case invocationPreparation
  case invocationReceipt
  case materialization
  case presentation
  case processExecution
  case processLaunch
}

public struct BazelOperationFailure: Equatable, Sendable {
  public let message: String
  public let phase: BazelOperationFailurePhase

  public init(phase: BazelOperationFailurePhase, message: String) {
    self.phase = phase
    self.message = message
  }
}

public struct BazelOperationExecutionResult: Equatable, Sendable {
  public let bep: BEPValidation?
  public let cleanReceipt: CleanReceipt?
  public let failure: BazelOperationFailure?
  public let invocationReceipt: InvocationReceipt?
  public let operationDirectoryURL: URL?
  public let processCompletion: ProcessCompletion?
  public let productReceipt: ProductReceipt?
  public let status: ProxyTerminalStatus

  public init(
    bep: BEPValidation? = nil,
    cleanReceipt: CleanReceipt? = nil,
    failure: BazelOperationFailure? = nil,
    invocationReceipt: InvocationReceipt? = nil,
    operationDirectoryURL: URL? = nil,
    processCompletion: ProcessCompletion? = nil,
    productReceipt: ProductReceipt? = nil,
    status: ProxyTerminalStatus
  ) {
    self.bep = bep
    self.cleanReceipt = cleanReceipt
    self.failure = failure
    self.invocationReceipt = invocationReceipt
    self.operationDirectoryURL = operationDirectoryURL
    self.processCompletion = processCompletion
    self.productReceipt = productReceipt
    self.status = status
  }
}

public protocol BazelOperationExecuting: Sendable {
  func execute(
    plan: ResolvedBuildPlan,
    processEnvironment: [String: String],
    onEvent: @escaping @Sendable (BazelOperationExecutionEvent) async throws -> Void
  ) async -> BazelOperationExecutionResult
}

/// Executes one already-resolved Bazel operation without importing Swift Build protocol types.
///
/// The caller owns protocol lifecycle and exactly-once terminalization. Cancelling the task that
/// awaits `execute` terminates the owned adapter process group and returns a cancelled result.
public struct BazelOperationExecutor: Sendable {
  public typealias EventHandler = @Sendable (BazelOperationExecutionEvent) async throws -> Void

  private let cancellationGrace: TimeInterval
  private let invocationPreparer: any AdapterInvocationPreparing
  private let materializer: ProductMaterializer
  private let processSupervisor: any ProcessSupervising

  public init(
    invocationPreparer: any AdapterInvocationPreparing = AdapterInvocationFactory(),
    processSupervisor: any ProcessSupervising = OwnedProcessSupervisor(),
    materializer: ProductMaterializer = ProductMaterializer(),
    cancellationGrace: TimeInterval = 2
  ) {
    self.invocationPreparer = invocationPreparer
    self.processSupervisor = processSupervisor
    self.materializer = materializer
    self.cancellationGrace = max(0, cancellationGrace)
  }

  public func execute(
    plan: ResolvedBuildPlan,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    onEvent: @escaping EventHandler = { _ in }
  ) async -> BazelOperationExecutionResult {
    let mutationCancellationGate = ProductMutationCancellationGate()
    if case .clean = plan.intent.action {
      return await withTaskCancellationHandler {
        executeClean(plan: plan, cancellationGate: mutationCancellationGate)
      } onCancel: {
        mutationCancellationGate.requestCancellation()
      }
    }
    guard !Task.isCancelled else {
      return BazelOperationExecutionResult(status: .cancelled)
    }

    let invocation: AdapterInvocation
    do {
      invocation = try invocationPreparer.make(
        for: plan,
        processEnvironment: processEnvironment
      )
    } catch {
      return failed(.invocationPreparation, error)
    }
    guard !Task.isCancelled else {
      return BazelOperationExecutionResult(
        operationDirectoryURL: invocation.operationDirectoryURL,
        status: .cancelled
      )
    }

    let process: any OwnedProcess
    do {
      process = try processSupervisor.spawn(invocation)
    } catch {
      return failed(
        .processLaunch,
        error,
        operationDirectoryURL: invocation.operationDirectoryURL
      )
    }

    let grace = cancellationGrace
    return await withTaskCancellationHandler {
      async let completionTask = process.wait()
      var presentationError: (any Error)?
      do {
        for await event in process.events {
          try Task.checkCancellation()
          try await onEvent(.processOutput(event))
        }
      } catch {
        presentationError = error
        _ = await process.cancel(gracePeriod: grace)
      }
      if Task.isCancelled {
        _ = await process.cancel(gracePeriod: grace)
      }
      let completion = await completionTask

      if Task.isCancelled {
        return BazelOperationExecutionResult(
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .cancelled
        )
      }
      if let presentationError {
        return failed(
          .presentation,
          presentationError,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }
      guard completion.succeeded else {
        return BazelOperationExecutionResult(
          failure: BazelOperationFailure(
            phase: .processExecution,
            message: Self.processFailureMessage(completion)
          ),
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: completion.cancellationRequested ? .cancelled : .failed
        )
      }

      let bep: BEPValidation
      do {
        bep = try BEPStreamValidator.validate(fileAt: invocation.bepURL)
      } catch {
        return failed(
          .bepValidation,
          error,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }

      let receipt: InvocationReceipt
      do {
        receipt = try InvocationReceiptValidator.loadAndValidate(
          for: plan,
          invocation: invocation
        )
      } catch {
        return failed(
          .invocationReceipt,
          error,
          bep: bep,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }

      do {
        for event in bep.events {
          try Task.checkCancellation()
          try await onEvent(.bep(event))
        }
      } catch {
        if Task.isCancelled {
          return BazelOperationExecutionResult(
            bep: bep,
            invocationReceipt: receipt,
            operationDirectoryURL: invocation.operationDirectoryURL,
            processCompletion: completion,
            status: .cancelled
          )
        }
        return failed(
          .presentation,
          error,
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }

      guard bep.result.succeeded else {
        return BazelOperationExecutionResult(
          bep: bep,
          failure: BazelOperationFailure(
            phase: .bepValidation,
            message: "Bazel reported a failed terminal build event."
          ),
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .failed
        )
      }
      guard !Task.isCancelled else {
        return BazelOperationExecutionResult(
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .cancelled
        )
      }

      if case .indexBuild = plan.intent.action {
        return BazelOperationExecutionResult(
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .succeeded
        )
      }

      do {
        let productReceipt = try materializer.materialize(
          plan: plan,
          cancellationGate: mutationCancellationGate
        )
        return BazelOperationExecutionResult(
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          productReceipt: productReceipt,
          status: .succeeded
        )
      } catch ProductMutationCancellationError.cancelledBeforeCommit {
        return BazelOperationExecutionResult(
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .cancelled
        )
      } catch {
        return failed(
          .materialization,
          error,
          bep: bep,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }
    } onCancel: {
      mutationCancellationGate.requestCancellation()
      Task {
        _ = await process.cancel(gracePeriod: grace)
      }
    }
  }

  private func executeClean(
    plan: ResolvedBuildPlan,
    cancellationGate: ProductMutationCancellationGate
  ) -> BazelOperationExecutionResult {
    guard !Task.isCancelled else {
      return BazelOperationExecutionResult(status: .cancelled)
    }
    do {
      let receipt = try materializer.clean(
        plan: plan,
        cancellationGate: cancellationGate
      )
      return BazelOperationExecutionResult(cleanReceipt: receipt, status: .succeeded)
    } catch ProductMutationCancellationError.cancelledBeforeCommit {
      return BazelOperationExecutionResult(status: .cancelled)
    } catch {
      return failed(.clean, error)
    }
  }

  private func failed(
    _ phase: BazelOperationFailurePhase,
    _ error: any Error,
    bep: BEPValidation? = nil,
    invocationReceipt: InvocationReceipt? = nil,
    operationDirectoryURL: URL? = nil,
    processCompletion: ProcessCompletion? = nil
  ) -> BazelOperationExecutionResult {
    BazelOperationExecutionResult(
      bep: bep,
      failure: BazelOperationFailure(
        phase: phase,
        message: error.localizedDescription
      ),
      invocationReceipt: invocationReceipt,
      operationDirectoryURL: operationDirectoryURL,
      processCompletion: processCompletion,
      status: .failed
    )
  }

  private static func processFailureMessage(_ completion: ProcessCompletion) -> String {
    switch completion.termination {
    case .exited(let status):
      return "The Bazel adapter exited with status \(status)."
    case .signalled(let signal):
      return "The Bazel adapter terminated after signal \(signal)."
    }
  }
}

extension BazelOperationExecutor: BazelOperationExecuting {}
