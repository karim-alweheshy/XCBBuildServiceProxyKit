import Foundation

public enum DiagnosticSeverity: String, Equatable, Hashable, Sendable {
  case error
  case note
  case remark
  case warning
}

public struct ProxyDiagnostic: Equatable, Hashable, Sendable {
  public let column: Int?
  public let line: Int?
  public let message: String
  public let path: String?
  public let severity: DiagnosticSeverity

  public init(
    column: Int?,
    line: Int?,
    message: String,
    path: String?,
    severity: DiagnosticSeverity
  ) {
    self.column = column
    self.line = line
    self.message = message
    self.path = path
    self.severity = severity
  }
}

public struct ProxyProgress: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    /// A presentation hint parsed from Bazel's progress text, not an action-count source of truth.
    case interactiveHint
    /// A structured count reported by BEP build metrics.
    case reportedExecutedActions
  }

  /// Bazel's sanitized, human-readable description of the work it currently reports.
  /// This remains a presentation hint and is never used to decide action success or cache state.
  public let activity: String?
  public let completed: Int
  public let source: Source
  public let total: Int?

  public init(
    activity: String? = nil,
    completed: Int,
    source: Source,
    total: Int?
  ) {
    self.activity = activity
    self.completed = completed
    self.source = source
    self.total = total
  }
}

public enum ProxyTerminalStatus: String, Equatable, Sendable {
  case cancelled
  case failed
  case succeeded
}

public enum ProxyLifecycleEvent: Equatable, Sendable {
  case operationStarted
  case operationEnded(ProxyTerminalStatus)
  case preparationCompleted
  case targetStarted(entityID: String)
  case targetEnded(entityID: String, status: ProxyTerminalStatus)
  case taskStarted(entityID: String)
  case taskEnded(entityID: String, status: ProxyTerminalStatus, signalled: Bool)
}

public enum ProxyEvent: Equatable, Sendable {
  case diagnostic(ProxyDiagnostic)
  case lifecycle(ProxyLifecycleEvent)
  case progress(ProxyProgress)
}

public enum DiagnosticParser {
  public static func parse(line originalLine: String) -> ProxyDiagnostic? {
    let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }

    let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
    if parts.count == 5,
      let lineNumber = Int(parts[1]),
      let columnNumber = Int(parts[2]),
      let severity = DiagnosticSeverity(
        rawValue: String(parts[3]).trimmingCharacters(in: .whitespaces)
      )
    {
      return ProxyDiagnostic(
        column: columnNumber,
        line: lineNumber,
        message: String(parts[4]).trimmingCharacters(in: .whitespaces),
        path: String(parts[0]),
        severity: severity
      )
    }

    for (prefix, severity): (String, DiagnosticSeverity) in [
      ("ERROR: ", .error),
      ("WARNING: ", .warning),
      ("NOTE: ", .note),
      ("REMARK: ", .remark),
    ] where line.hasPrefix(prefix) {
      return ProxyDiagnostic(
        column: nil,
        line: nil,
        message: String(line.dropFirst(prefix.count)),
        path: nil,
        severity: severity
      )
    }
    return nil
  }
}

/// Projects the validated BEP allowlist into events a build-service bridge can translate without
/// importing Bazel or Swift Build protocol types. BEP completion records have no corresponding
/// start records in this allowlist, so each completion becomes an adjacent synthetic start/end
/// pair. Consumers therefore never observe an orphan lifecycle end.
public enum ProxyEventProjection {
  public static func project(_ event: BEPEvent) -> [ProxyEvent] {
    switch event {
    case .actionCompleted(let action):
      guard let succeeded = action.succeeded else { return [] }
      return [
        .lifecycle(.taskStarted(entityID: action.identity)),
        .lifecycle(
          .taskEnded(
            entityID: action.identity,
            status: succeeded ? .succeeded : .failed,
            signalled: false
          )
        ),
      ]
    case .buildMetadata:
      return []
    case .progress(let progress):
      return [.progress(progress)]
    case .reportedExecutedActionCount(let count):
      return [
        .progress(
          ProxyProgress(completed: count, source: .reportedExecutedActions, total: nil)
        )
      ]
    case .targetCompleted(let label, let succeeded):
      return [
        .lifecycle(.targetStarted(entityID: label)),
        .lifecycle(.targetEnded(entityID: label, status: succeeded ? .succeeded : .failed)),
      ]
        + (succeeded
          ? []
          : [
            .diagnostic(
              ProxyDiagnostic(
                column: nil,
                line: nil,
                message: "Bazel target failed: \(label)",
                path: nil,
                severity: .error
              )
            )
          ])
    case .finished(let succeeded):
      return [
        .lifecycle(.operationStarted),
        .lifecycle(.operationEnded(succeeded ? .succeeded : .failed)),
      ]
    }
  }
}
