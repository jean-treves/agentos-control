import Foundation

/// What the floor and the run detail show about one run, folded from its journal events.
/// Folding is incremental (poll with `after_seq: lastSeq`) and idempotent.
nonisolated struct RunActivity: Equatable, Sendable {
    private(set) var engine: String?
    private(set) var lastTool: String?
    private(set) var toolCalls = 0
    private(set) var lastSeq = 0
    private(set) var journalEvents = 0

    /// `policy.yaml › budgets.max_tool_calls`. host-v1 does not expose the policy, so a change
    /// there must be mirrored here (ponytail: add the budget to a host route if it ever moves).
    static let defaultMaxToolCalls = 60

    func folding(_ events: [JournalEvent]) -> RunActivity {
        var next = self
        for event in events where event.seq > next.lastSeq {
            next.lastSeq = event.seq
            next.journalEvents += 1
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

extension RunDetail {
    /// The run detail's header. It counts the run's journal events, not `events`: that stream (`run_events`)
    /// has been written by no production code since the T1.11 server split, so it is empty for every
    /// governed run (hermes-cli included) and the header used to read « 0 événements » next to a full journal.
    nonisolated func statusLine(activity: RunActivity) -> String {
        let count = activity.journalEvents
        return "\(status) · \(source ?? "?") · \(activity.engine ?? "moteur ?") · journal : \(count) événement\(count > 1 ? "s" : "")"
    }
}

extension RunDetail {
    /// Haiku's notes about a run (`haiku.note`, `haiku.summary`: 90 s at most each) are journaled after
    /// `run.ended`; the timeline keeps listening that long.
    nonisolated static let lateReceipts: TimeInterval = 120

    /// While the run runs, and for `lateReceipts` after it ended: `updatedAt` is set by `run_store.finish` at
    /// the end. An old run is read once; polling it would reread the whole journal every 2 s for nothing.
    nonisolated func keepsListening(at now: Date) -> Bool {
        guard status != "running" else { return true }
        guard let updatedAt else { return false }
        return now.timeIntervalSince1970 - Double(updatedAt) <= Self.lateReceipts
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
        case "arbiter.decided": [data?.decision, data?.request, data?.reason]
        case "haiku.note": [data?.trigger, data?.haikuText]
        case "haiku.summary": [data?.validated == true ? nil : "non validé", data?.haikuText]  // F11, D45
        case "brief.validated", "brief.launched": [data?.brief]
        case "brief.widened": [data?.to, data?.why]
        case "supervisor.killed", "review.skipped": [data?.reason]
        default: []
        }
        // Every part is the journal's text: the executor's own command, its words, a raw error. One line, no
        // bidi override: a new line would hide the end of a command behind the timeline's two-line limit.
        return parts.compactMap { $0?.plainText() }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension EventData {
    /// Haiku's note, or the fact that it did not answer: a failed call is journaled with an empty note.
    nonisolated var haikuText: String? {
        guard ok == false else { return note }
        return "Haiku sans réponse" + (error.map { " (\($0))" } ?? "")
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
