import Foundation

/// What the floor and the run detail show about one run, folded from its journal events.
/// Folding is incremental (poll with `after_seq: lastSeq`) and idempotent.
nonisolated struct RunActivity: Equatable, Sendable {
    private(set) var engine: String?
    private(set) var lastTool: String?
    private(set) var toolCalls = 0
    private(set) var lastSeq = 0

    /// `policy.yaml › budgets.max_tool_calls`. host-v1 does not expose the policy, so a change
    /// there must be mirrored here (ponytail: add the budget to a host route if it ever moves).
    static let defaultMaxToolCalls = 60

    func folding(_ events: [JournalEvent]) -> RunActivity {
        var next = self
        for event in events where event.seq > next.lastSeq {
            next.lastSeq = event.seq
            next.engine = next.engine ?? event.engine
            // One `tool.requested` per tool call: the count the budget tracker compares.
            if event.type == "tool.requested" {
                next.toolCalls += 1
                next.lastTool = event.data?.tool ?? next.lastTool
            }
        }
        return next
    }

    func remainingToolCalls(limit: Int) -> Int { max(0, limit - toolCalls) }

    /// The task's `budget.max_tool_calls` when the run belongs to a task that overrides it.
    static func toolCallLimit(for run: RunSummary, tasks: [AgentTask]) -> Int {
        guard let taskId = run.taskId else { return defaultMaxToolCalls }
        return tasks.first { $0.taskId == taskId }?.budget?.maxToolCalls ?? defaultMaxToolCalls
    }
}

extension RunDetail {
    /// The list row of this run, so detail screens reuse the summary helpers (`taskId`, budget).
    nonisolated var asSummary: RunSummary {
        RunSummary(runId: runId, prompt: prompt, source: source, status: status, createdAt: createdAt,
                   updatedAt: updatedAt)
    }
}

extension JournalEvent {
    /// One readable line per receipt; empty for events that need no detail.
    nonisolated var summary: String {
        let data = data
        let parts: [String?] = switch type {
        case "decision": [data?.verdict, data?.tool ?? data?.capability, data?.decider, data?.rule]
        case "tool.requested": [data?.tool, data?.inputExcerpt]
        case "approval.waiting": [data?.capability, data?.targetExcerpt]
        case "approval.resolved":
            [data?.approved.map { $0 ? "approuvé" : "refusé" }.map { "\($0) par \(data?.decider ?? "?")" }]
        case "run.ended": [data?.status]
        case "budget.tripped": [data?.reason]
        default: []
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

extension TaskAction {
    /// What the host can meaningfully do from each task status (kernel/tasks.py).
    nonisolated static func available(for status: String) -> [TaskAction] {
        switch status {
        case "paused": [.resume, .cancel]
        case "queued", "deferred": [.pause, .cancel]
        default: []
        }
    }

    var label: String {
        switch self {
        case .cancel: "Annuler"
        case .pause: "Pause"
        case .resume: "Reprendre"
        }
    }
}

/// Tasks list filter. "En cours" hides the terminal statuses; a status the app does not know yet stays visible.
nonisolated enum TaskFilter: String, CaseIterable, Identifiable, Sendable {
    case inProgress, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inProgress: "En cours"
        case .all: "Toutes"
        }
    }

    /// kernel/tasks.py `TASK_STATUSES`: these four end a task; queued, running, waiting_approval, deferred
    /// and paused are still in progress.
    static let terminalStatuses: Set<String> = ["done", "failed", "killed", "cancelled"]

    func apply(to tasks: [AgentTask]) -> [AgentTask] {
        switch self {
        case .all: tasks
        case .inProgress: tasks.filter { !Self.terminalStatuses.contains($0.status) }
        }
    }

    /// What the list says when the filter leaves nothing; `total` is the unfiltered count.
    func emptyState(total: Int) -> (title: String, detail: String?) {
        switch self {
        case .all: ("Aucune tâche", nil)
        case .inProgress: ("Aucune tâche en cours", total == 0 ? nil : "\(total) tâche\(total > 1 ? "s" : "") au total")
        }
    }
}

extension NewTask {
    /// `TaskIn` requires both; whitespace-only would create an empty agent run.
    nonisolated var isSubmittable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
