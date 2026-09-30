import Foundation

// host-v1.json declares no response schemas (every 200 is an untyped object), so these shapes come
// from server/routers/host.py and live GETs (2026-09-23). Anything the server may null or omit is
// optional: one odd row must not blank a whole screen. Keys arrive snake_case and are converted by
// HostClient's decoder (`run_id` → `runId`).

/// `GET /api/approvals/pending` row. `capability`, `target`, `run_id` are nullable in approvals.db.
nonisolated struct Approval: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let ts: Int
    let capability: String?
    let target: String?
    let runId: String?
    let timeoutAt: Int
    /// SP8 origin (spec §17.5); nil for requests from before SP8 or from the gateway.
    var actionClass: String? = nil
    var originEngine: String? = nil
    var originModel: String? = nil
    var originMode: String? = nil
    var escalatedBy: String? = nil
    var reason: String? = nil

    var deadline: Date { Date(timeIntervalSince1970: TimeInterval(timeoutAt)) }
}

/// `GET /api/runs` row (no events).
nonisolated struct RunSummary: Decodable, Sendable, Hashable, Identifiable {
    let runId: String
    let prompt: String?
    let source: String?
    let status: String
    let createdAt: Int
    let updatedAt: Int?

    var id: String { runId }
    var isRunning: Bool { status == "running" }
    var created: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    /// Governed task runs carry `source = "task:<task_id>"`.
    var taskId: String? {
        guard let source, source.hasPrefix("task:") else { return nil }
        return String(source.dropFirst("task:".count))
    }
}

/// Stream event stored with a run. Its `data` is engine-specific (object or plain string), so only
/// the envelope is decoded; the governance detail comes from the journal.
nonisolated struct RunEvent: Decodable, Sendable, Hashable {
    let seq: Int
    let event: String
}

/// `GET /api/runs/{run_id}?after=` : one run plus its stream events after `after`.
nonisolated struct RunDetail: Decodable, Sendable, Hashable {
    let runId: String
    let prompt: String?
    let source: String?
    let status: String
    let output: String?
    let createdAt: Int
    let updatedAt: Int?
    let events: [RunEvent]
}

/// `GET /api/journal` event (hash-chained governance journal).
nonisolated struct JournalEvent: Decodable, Sendable, Hashable, Identifiable {
    let seq: Int
    let ts: String
    let runId: String?
    let taskId: String?
    let engine: String?
    let type: String
    let data: EventData?

    var id: Int { seq }
    var date: Date? { parseTimestamp(ts) }

    private enum CodingKeys: String, CodingKey { case seq, ts, runId, taskId, engine, type, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        ts = try container.decodeIfPresent(String.self, forKey: .ts) ?? ""
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        type = try container.decode(String.self, forKey: .type)
        // `data` is free-form per event type: an unexpected shape drops the detail, not the event.
        data = try? container.decodeIfPresent(EventData.self, forKey: .data)
    }
}

/// The journal `data` fields the app displays; every other key is ignored.
nonisolated struct EventData: Decodable, Sendable, Hashable {
    let tool: String?
    let capability: String?
    let verdict: String?
    let decider: String?
    let rule: String?
    let profile: String?
    let reason: String?
    let status: String?
    let targetExcerpt: String?
    let inputExcerpt: String?
    let approvalId: String?
    let approved: Bool?
    let isError: Bool?
}

/// `GET /api/tasks` row (kernel/tasks.py `Task`).
nonisolated struct AgentTask: Decodable, Sendable, Hashable, Identifiable {
    let taskId: String
    let title: String
    let prompt: String?
    let project: String?
    let engine: String
    let profile: String
    let schedule: String?
    let priority: Int?
    let budget: TaskBudget?
    let status: String
    let pausedReason: String?
    let source: String?
    let createdAt: String?
    let updatedAt: String?

    var id: String { taskId }
    var created: Date? { createdAt.flatMap(parseTimestamp) }
}

/// A task's budget override. The CLI stores whatever JSON it was given, so a non-integer value
/// reads as "no override" instead of failing the whole task list.
nonisolated struct TaskBudget: Decodable, Sendable, Hashable {
    let maxToolCalls: Int?

    private enum CodingKeys: String, CodingKey { case maxToolCalls }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxToolCalls = try? container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
    }
}

/// Body of `POST /api/tasks` (schema `TaskIn`); the server stamps `source=app`.
/// `schedule`, `priority` and `budget` keep their server defaults.
nonisolated struct NewTask: Encodable, Sendable, Hashable {
    var title: String
    var prompt: String
    var project: String
    var engine: String
    var profile: String
}

/// Path segment of `POST /api/tasks/{task_id}/{action}`; the server knows exactly these three.
nonisolated enum TaskAction: String, Sendable, CaseIterable {
    case cancel, pause, resume
}

/// `GET /api/breaker` and `POST /api/breaker/reset`.
nonisolated struct BreakerStatus: Decodable, Sendable, Hashable {
    let consecutiveFailures: Int?
    let openedAt: Double?
    let canLaunch: Bool
    let reason: String?
}

/// The few `/api/glance` fields the Overview shows (the cockpit reads the rest).
nonisolated struct Glance: Decodable, Sendable, Hashable {
    let offers: Int?
    let jobsDate: String?
    let reclaimGb: Double?
    let scanDate: String?
}

/// `GET /api/health/deep` (kernel/health.py `deep_check`).
nonisolated struct DeepHealth: Decodable, Sendable, Hashable {
    let ok: Bool
    let generatedAt: String?
    let checks: [HealthCheck]

    var generated: Date? { generatedAt.flatMap(parseTimestamp) }
}

nonisolated struct HealthCheck: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let ok: Bool
    let detail: String?

    var id: String { name }
}

/// The host writes `…12.017Z` (journal), `…+00:00` with or without microseconds (tasks) and
/// `…+0200` (deep health); the default ISO 8601 style parses all three.
nonisolated func parseTimestamp(_ text: String) -> Date? {
    try? Date.ISO8601FormatStyle().parse(text)
}

/// One `/api/memory/search` result: the vault index (SP4). Text is already redacted by the host.
nonisolated struct VaultHit: Decodable, Sendable, Hashable, Identifiable {
    let source: String
    let path: String
    let snippet: String?
    let score: Double?
    var id: String { path }
}

/// One `/api/memory/query` result: an ai-memory session or handoff page.
nonisolated struct MemoryHit: Decodable, Sendable, Hashable, Identifiable {
    let path: String
    let title: String
    let snippet: String?
    let project: String?
    let workspace: String?
    let rank: Double?
    var id: String { "\(workspace ?? "")/\(project ?? "")/\(path)" }
}

/// `GET /api/memory/page`.
nonisolated struct MemoryPage: Decodable, Sendable, Hashable, Identifiable {
    let path: String
    let title: String
    let body: String
    var id: String { path }
}

/// `GET /api/status`: only the disk is read here (the rest feeds the web cockpit).
nonisolated struct StatusPayload: Decodable, Sendable {
    let disk: DiskStatus?
}

nonisolated struct DiskStatus: Decodable, Sendable, Hashable {
    let freeGb: Double
    let totalGb: Double
    let usedPct: Int
}

/// `GET /api/optimize/latest` (documents/optimize-*.json written by the /optimize scan).
nonisolated struct OptimizeReport: Decodable, Sendable, Hashable {
    let generatedAt: String?
    let findings: [Finding]
}

nonisolated struct Finding: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let category: String
    let title: String
    let description: String?
    let command: String?
    let riskLevel: String?
    let oneClickSafe: Bool?
    let estimatedImpactMb: Double?
}

/// One job-radar offer. Text and `url` are scraped: the app only displays them and opens `http(s)` links.
nonisolated struct JobOffer: Decodable, Sendable, Hashable, Identifiable {
    let title: String
    let company: String
    let url: String?
    let stars: Int?
    let why: String?
    let location: String?
    let country: String?
    let posted: String?
    let source: String?
    var id: String { url ?? "\(company)|\(title)" }
}

/// `GET /api/jobsearch/merged`. The host's `errors` field is not decoded on purpose: it holds the
/// upstream error text, which includes the failing request URL (with its API credentials).
nonisolated struct MergedOffers: Decodable, Sendable {
    let offers: [JobOffer]
    let reportDate: String?
}

/// `GET /api/jobsearch/applications`.
nonisolated struct Applications: Decodable, Sendable {
    let total: Int?
    let funnel: [String: Int]?
    let due: [IgnoredItem]?
}

/// An array element whose content the app does not show (only the count matters).
nonisolated struct IgnoredItem: Decodable, Sendable, Hashable {
    init(from decoder: any Decoder) throws {}
}

/// `POST /api/optimize/run` and `POST /api/jobsearch/run`.
nonisolated struct LaunchReply: Decodable, Sendable, Hashable {
    let started: Bool
    let reason: String?
}

/// One entry of `GET /api/commands` (spec §15.2): the app builds its form from it.
nonisolated struct CommandSpec: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let title: String
    let description: String
    /// true: the app opens a dedicated window (Pitch) instead of the generic form.
    let interactive: Bool
    let params: [CommandParam]
    var id: String { name }
}

nonisolated struct CommandParam: Decodable, Sendable, Hashable {
    let name: String
    let label: String
    /// `text`, `choice` or `datetime` (ISO 8601).
    let kind: String
    let choices: [String]?
    let defaultValue: String?
    let required: Bool
    /// Shown instead of the value (`accept_diffs` → « Accepter les diffs »); absent for most fields.
    var labels: [String: String]? = nil

    enum CodingKeys: String, CodingKey { case name, label, kind, choices, defaultValue = "default", required, labels }
}

/// `POST /api/commands/{name}`: tasks created, runs started (none for a scheduled command), or
/// the result of an immediate action (a promotion).
nonisolated struct CommandLaunch: Decodable, Sendable, Hashable {
    let command: String
    let taskIds: [String]
    let runIds: [String]
    let result: [String: String]?

    fileprivate enum CodingKeys: String, CodingKey { case command, taskIds, runIds, result }
}

extension CommandLaunch {
    /// The host has already acted when this is decoded: a `result` value that is not a string (a number,
    /// a list) is shown as text, not allowed to fail the whole reply and invite a second launch.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        taskIds = try container.decode([String].self, forKey: .taskIds)
        runIds = try container.decode([String].self, forKey: .runIds)
        result = try container.decodeIfPresent([String: LooseText?].self, forKey: .result)?
            .compactMapValues { $0?.text }
    }
}

/// A JSON scalar read as text; null is dropped by the caller, a list or object becomes a placeholder.
nonisolated private struct LooseText: Decodable {
    let text: String

    nonisolated init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { text = string }
        else if let flag = try? value.decode(Bool.self) { text = flag ? "true" : "false" }
        else if let integer = try? value.decode(Int.self) { text = String(integer) }
        else if let number = try? value.decode(Double.self) { text = String(number) }
        else { text = "(valeur non textuelle)" }
    }
}
