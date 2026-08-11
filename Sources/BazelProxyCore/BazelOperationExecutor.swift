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
  case action(BazelPresentedAction)
  case actionStarted(BazelActionStarted)
  case actionSummary(BazelActionPresentationSummary)
  case bep(BEPEvent)
  case processOutput(ProcessOutputEvent)
}

public enum BazelOperationFailurePhase: String, Equatable, Sendable {
  case actionStartValidation
  case actionGraphValidation
  case bepValidation
  case clean
  case executionLogValidation
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
  public let actionStarts: BazelActionStartValidation?
  public let bep: BEPValidation?
  public let cleanReceipt: CleanReceipt?
  public let configuredActionGraph: ConfiguredActionGraphValidation?
  public let failure: BazelOperationFailure?
  public let executionLog: BazelExecutionLogValidation?
  public let invocationReceipt: InvocationReceipt?
  public let operationDirectoryURL: URL?
  public let processCompletion: ProcessCompletion?
  public let productReceipt: ProductReceipt?
  public let status: ProxyTerminalStatus

  public init(
    actionStarts: BazelActionStartValidation? = nil,
    bep: BEPValidation? = nil,
    cleanReceipt: CleanReceipt? = nil,
    configuredActionGraph: ConfiguredActionGraphValidation? = nil,
    failure: BazelOperationFailure? = nil,
    executionLog: BazelExecutionLogValidation? = nil,
    invocationReceipt: InvocationReceipt? = nil,
    operationDirectoryURL: URL? = nil,
    processCompletion: ProcessCompletion? = nil,
    productReceipt: ProductReceipt? = nil,
    status: ProxyTerminalStatus
  ) {
    self.actionStarts = actionStarts
    self.bep = bep
    self.cleanReceipt = cleanReceipt
    self.configuredActionGraph = configuredActionGraph
    self.failure = failure
    self.executionLog = executionLog
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
      let completionSignal = AdapterCompletionSignal()
      let completionTask = Task {
        let completion = await process.wait()
        await completionSignal.markComplete()
        return completion
      }
      let bepTask = Task {
        await Self.followBEP(
          fileAt: invocation.bepURL,
          process: process,
          completionSignal: completionSignal,
          cancellationGrace: grace,
          onEvent: onEvent
        )
      }
      let actionStartTask = Task {
        await Self.followActionStarts(
          fileAt: invocation.actionStartsURL,
          process: process,
          completionSignal: completionSignal,
          cancellationGrace: grace,
          onEvent: onEvent
        )
      }
      var presentationError: (any Error)?
      do {
        for await event in process.events {
          try Task.checkCancellation()
          try await onEvent(.processOutput(event))
        }
      } catch {
        presentationError = error
        process.events.cancel()
        _ = await process.cancel(gracePeriod: grace)
      }
      if Task.isCancelled {
        process.events.cancel()
        _ = await process.cancel(gracePeriod: grace)
      }
      let completion = await completionTask.value
      let bepOutcome = await bepTask.value
      let actionStartOutcome = await actionStartTask.value

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
      let actionStarts: BazelActionStartValidation?
      switch actionStartOutcome {
      case .success(let validation):
        actionStarts = validation
      case .failure(let phase, let message):
        return failed(
          phase,
          BEPEventPresentationError(message: message),
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }
      if completion.cancellationRequested,
        case .failure(let phase, let message) = bepOutcome
      {
        return failed(
          phase,
          BEPEventPresentationError(message: message),
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }
      guard completion.succeeded else {
        return BazelOperationExecutionResult(
          actionStarts: actionStarts,
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
      switch bepOutcome {
      case .success(let validation):
        bep = validation
      case .failure(let phase, let message):
        return failed(
          phase,
          BEPEventPresentationError(message: message),
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

      let configuredActionGraph: ConfiguredActionGraphValidation?
      if case .indexBuild = plan.intent.action {
        configuredActionGraph = nil
      } else if FileManager.default.fileExists(atPath: invocation.actionGraphURL.path) {
        do {
          configuredActionGraph = try ConfiguredActionGraphValidator.validate(
            fileAt: invocation.actionGraphURL,
            productPaths: Set(plan.targets.compactMap(\.mapping.product.path)),
            configurations: Set(plan.targets.compactMap(Self.configurationName))
          )
        } catch {
          return failed(
            .actionGraphValidation,
            error,
            bep: bep,
            invocationReceipt: receipt,
            operationDirectoryURL: invocation.operationDirectoryURL,
            processCompletion: completion
          )
        }
      } else {
        configuredActionGraph = nil
      }

      let executionLog: BazelExecutionLogValidation?
      if FileManager.default.fileExists(atPath: invocation.executionLogURL.path) {
        do {
          executionLog = try BazelExecutionLogValidator.validate(fileAt: invocation.executionLogURL)
        } catch {
          return failed(
            .executionLogValidation,
            error,
            bep: bep,
            configuredActionGraph: configuredActionGraph,
            invocationReceipt: receipt,
            operationDirectoryURL: invocation.operationDirectoryURL,
            processCompletion: completion
          )
        }
      } else {
        executionLog = nil
      }

      do {
        let completedActions = bep.events.compactMap { event -> BEPActionCompleted? in
          guard case .actionCompleted(let action) = event, action.succeeded != nil else {
            return nil
          }
          return action
        }
        let configuredByKey = Dictionary(
          uniqueKeysWithValues: (configuredActionGraph?.actions ?? []).map {
            ($0.reconciliationKey, $0)
          }
        )
        let completedActionKeys = Set(completedActions.map(\.reconciliationKey))
        var cacheHits = 0
        var completedStatusUnavailable = 0
        var executed = 0
        for event in bep.events {
          try Task.checkCancellation()
          switch event {
          case .actionCompleted(let action) where action.succeeded != nil:
            let record = executionLog?.record(for: action.reconciliationKey)
            let presented = BazelPresentedAction(
              completed: action,
              configured: configuredByKey[action.reconciliationKey],
              executionRecord: record
            )
            switch presented.disposition {
            case .cacheHit:
              cacheHits += 1
            case .completed:
              completedStatusUnavailable += 1
            case .executed:
              executed += 1
            case .upToDate:
              break
            }
            try await onEvent(.action(presented))
          case .reportedExecutedActionCount where configuredActionGraph != nil:
            break
          default:
            break
          }
        }
        if bep.result.succeeded, let configuredActionGraph {
          let remaining = configuredActionGraph.actions.filter {
            !completedActionKeys.contains($0.reconciliationKey)
          }
          var upToDate = 0
          for action in remaining {
            try Task.checkCancellation()
            if let record = executionLog?.record(for: action.reconciliationKey) {
              let presented = BazelPresentedAction(configured: action, executionRecord: record)
              if case .cacheHit = presented.disposition { cacheHits += 1 } else { executed += 1 }
              try await onEvent(.action(presented))
            } else {
              upToDate += 1
              try await onEvent(.action(BazelPresentedAction(upToDate: action)))
            }
          }
          try await onEvent(
            .actionSummary(
              BazelActionPresentationSummary(
                cacheHits: cacheHits,
                completedStatusUnavailable: completedStatusUnavailable,
                executed: executed,
                presented: completedActions.count + remaining.count,
                upToDate: upToDate
              )
            )
          )
        }
      } catch {
        if Task.isCancelled {
          return BazelOperationExecutionResult(
            actionStarts: actionStarts,
            bep: bep,
            configuredActionGraph: configuredActionGraph,
            executionLog: executionLog,
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
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion
        )
      }

      guard bep.result.succeeded else {
        return BazelOperationExecutionResult(
          actionStarts: actionStarts,
          bep: bep,
          configuredActionGraph: configuredActionGraph,
          failure: BazelOperationFailure(
            phase: .bepValidation,
            message: "Bazel reported a failed terminal build event."
          ),
          executionLog: executionLog,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .failed
        )
      }
      guard !Task.isCancelled else {
        return BazelOperationExecutionResult(
          actionStarts: actionStarts,
          bep: bep,
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          status: .cancelled
        )
      }

      if case .indexBuild = plan.intent.action {
        return BazelOperationExecutionResult(
          actionStarts: actionStarts,
          bep: bep,
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
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
          actionStarts: actionStarts,
          bep: bep,
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
          invocationReceipt: receipt,
          operationDirectoryURL: invocation.operationDirectoryURL,
          processCompletion: completion,
          productReceipt: productReceipt,
          status: .succeeded
        )
      } catch ProductMutationCancellationError.cancelledBeforeCommit {
        return BazelOperationExecutionResult(
          actionStarts: actionStarts,
          bep: bep,
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
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
          configuredActionGraph: configuredActionGraph,
          executionLog: executionLog,
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

  private static func followActionStarts(
    fileAt url: URL,
    process: any OwnedProcess,
    completionSignal: AdapterCompletionSignal,
    cancellationGrace: TimeInterval,
    onEvent: @escaping EventHandler
  ) async -> StreamingActionStartOutcome {
    do {
      let validation = try await BazelActionStartStreamFollower().follow(
        fileAt: url,
        processIsComplete: {
          await completionSignal.isComplete
        },
        onEvent: { start in
          do {
            try await onEvent(.actionStarted(start))
          } catch {
            throw BEPEventPresentationError(message: error.localizedDescription)
          }
        }
      )
      return .success(validation)
    } catch let error as BEPEventPresentationError {
      _ = await process.cancel(gracePeriod: cancellationGrace)
      return .failure(.presentation, error.localizedDescription)
    } catch {
      _ = await process.cancel(gracePeriod: cancellationGrace)
      return .failure(.actionStartValidation, error.localizedDescription)
    }
  }

  private static func followBEP(
    fileAt url: URL,
    process: any OwnedProcess,
    completionSignal: AdapterCompletionSignal,
    cancellationGrace: TimeInterval,
    onEvent: @escaping EventHandler
  ) async -> StreamingBEPOutcome {
    do {
      let validation = try await BEPStreamFollower().follow(
        fileAt: url,
        processIsComplete: {
          await completionSignal.isComplete
        },
        onEvent: { event in
          do {
            try await onEvent(.bep(event))
          } catch {
            throw BEPEventPresentationError(message: error.localizedDescription)
          }
        }
      )
      return .success(validation)
    } catch let error as BEPEventPresentationError {
      _ = await process.cancel(gracePeriod: cancellationGrace)
      return .failure(.presentation, error.localizedDescription)
    } catch {
      _ = await process.cancel(gracePeriod: cancellationGrace)
      return .failure(.bepValidation, error.localizedDescription)
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
    configuredActionGraph: ConfiguredActionGraphValidation? = nil,
    executionLog: BazelExecutionLogValidation? = nil,
    invocationReceipt: InvocationReceipt? = nil,
    operationDirectoryURL: URL? = nil,
    processCompletion: ProcessCompletion? = nil
  ) -> BazelOperationExecutionResult {
    BazelOperationExecutionResult(
      bep: bep,
      configuredActionGraph: configuredActionGraph,
      failure: BazelOperationFailure(
        phase: phase,
        message: error.localizedDescription
      ),
      executionLog: executionLog,
      invocationReceipt: invocationReceipt,
      operationDirectoryURL: operationDirectoryURL,
      processCompletion: processCompletion,
      status: .failed
    )
  }

  private static func processFailureMessage(_ completion: ProcessCompletion) -> String {
    let outputFailure: String?
    switch completion.outputDisposition {
    case .complete:
      outputFailure = nil
    case .bufferLimitExceeded(let channel):
      outputFailure = "The \(channel.rawValue) event buffer limit was exceeded."
    case .byteLimitExceeded(let channel):
      outputFailure = "The \(channel.rawValue) output byte limit was exceeded."
    case .consumerStopped(let channel):
      outputFailure = "The \(channel.rawValue) output consumer stopped."
    case .drainTimedOut:
      outputFailure = "The adapter output drain timed out."
    case .readFailed(let channel, let errno):
      outputFailure = "Reading \(channel.rawValue) failed with errno \(errno)."
    }
    if let outputFailure {
      return outputFailure
    }
    switch completion.termination {
    case .exited(let status):
      return "The Bazel adapter exited with status \(status)."
    case .signalled(let signal):
      return "The Bazel adapter terminated after signal \(signal)."
    }
  }

  private static func configurationName(_ target: ResolvedTargetPlan) -> String? {
    guard let path = target.mapping.product.path else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1, components[0] == "bazel-out" else { return nil }
    return String(components[1])
  }
}

extension BazelOperationExecutor: BazelOperationExecuting {}

private actor AdapterCompletionSignal {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}

private struct BEPEventPresentationError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private enum StreamingBEPOutcome: Sendable {
  case failure(BazelOperationFailurePhase, String)
  case success(BEPValidation)
}

private enum StreamingActionStartOutcome: Sendable {
  case failure(BazelOperationFailurePhase, String)
  case success(BazelActionStartValidation?)
}
