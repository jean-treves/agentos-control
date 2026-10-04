import Foundation
import os

/// Why a host call failed. Messages are shown to JT as is.
nonisolated enum HostError: Error, Equatable, Sendable, LocalizedError {
    /// Transport failure: host down, timeout, connection refused.
    case unreachable(String)
    /// No control token on this Mac (or read-only mode): the request was never sent.
    case tokenUnavailable
    /// 503 without a readable reason: the host has no control token in its Keychain.
    case controlDisabled
    /// 401: the host rejected the token.
    case unauthorized
    case notFound
    case http(Int)
    /// Any other non-2xx (503 included) that carries FastAPI's `{"detail": "…"}`: the host's own reason.
    /// Shown as is; not every route redacts it yet (the 400 of `/api/commands` does not), so it is host
    /// text, rendered verbatim, never parsed.
    case host(Int, String)
    /// 400/422: the host refused the parameters; carries its own reason, same caveat as `host`.
    case refused(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Host injoignable (\(detail))."
        case .tokenUnavailable: "Jeton de contrôle introuvable dans le Trousseau : rien n'a été envoyé."
        case .controlDisabled: "Le host n'a pas de jeton de contrôle (503)."
        case .unauthorized: "Jeton de contrôle refusé par le host (401)."
        case .notFound: "Introuvable (404)."
        case .http(let status): "Erreur HTTP \(status)."
        case .host(let status, let detail): "\(detail) (HTTP \(status))."
        case .refused(let reason): "Refusé par le host : \(reason)"
        case .decoding(let detail): "Réponse illisible (\(detail))."
        }
    }

    /// The message for a request that may have reached the host: when the answer never came back (a timeout,
    /// a dropped connection) the host may have acted all the same, and JT must look before he tries again.
    var descriptionAfterSend: String {
        guard case .unreachable = self else { return localizedDescription }
        return localizedDescription + " Le host a peut-être agi : vérifie Tâches et la conversation avant de recommencer."
    }
}

/// Client of the host-v1 API (docs/api/host-v1.md). GETs are unauthenticated; control routes carry
/// `Authorization: Bearer <token>` and are refused locally, unsent, when no token can be read.
actor HostClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias TokenProvider = @Sendable () async throws -> String?

    nonisolated let baseURL: URL
    private let token: TokenProvider
    private let transport: Transport
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "host")
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(baseURL: URL, token: @escaping TokenProvider, transport: @escaping Transport = HostClient.urlSession) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// `deep_check` probes Hermès then Ollama at 4 s each. A request's own `timeoutInterval`
    /// overrides the session's 5 s (measured 2026-09-25), so only this call waits longer.
    static let deepHealthTimeout: TimeInterval = 15

    /// A command that waits for a Claude call (`menage`: Haiku, 90 s at most, plus the size of every candidate).
    static let slowCommandTimeout: TimeInterval = 150

    /// Local host: fail fast, never cache responses on disk.
    static let urlSession: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return { request in try await session.data(for: request) }
    }()

    // MARK: Reads (no auth)

    func health() async throws(HostError) -> Bool {
        try await get(OkEnvelope.self, "/api/health").ok
    }

    func deepHealth() async throws(HostError) -> DeepHealth {
        try await get(DeepHealth.self, "/api/health/deep", timeout: Self.deepHealthTimeout)
    }

    func glance() async throws(HostError) -> Glance {
        try await get(Glance.self, "/api/glance")
    }

    func killSwitch() async throws(HostError) -> Bool {
        try await get(KillSwitchEnvelope.self, "/api/killswitch").killswitch
    }

    func pendingApprovals() async throws(HostError) -> [Approval] {
        try await get(PendingEnvelope.self, "/api/approvals/pending").pending
    }

    func runs(limit: Int) async throws(HostError) -> [RunSummary] {
        try await get(RunsEnvelope.self, "/api/runs", query: ["limit": "\(limit)"]).runs
    }

    func run(id: String, after: Int) async throws(HostError) -> RunDetail {
        try await get(RunDetail.self, "/api/runs/\(id)", query: ["after": "\(after)"])
    }

    func journal(afterSeq: Int, runID: String?) async throws(HostError) -> [JournalEvent] {
        var query = ["after_seq": "\(afterSeq)"]
        query["run_id"] = runID
        return try await get(JournalEnvelope.self, "/api/journal", query: query).events
    }

    func tasks() async throws(HostError) -> [AgentTask] {
        try await get(TasksEnvelope.self, "/api/tasks").tasks
    }

    func breaker() async throws(HostError) -> BreakerStatus {
        try await get(BreakerStatus.self, "/api/breaker")
    }

    func vaultSearch(_ query: String) async throws(HostError) -> [VaultHit] {
        try await get(VaultEnvelope.self, "/api/memory/search", query: ["q": query, "k": "20"]).results
    }

    func memoryQuery(_ query: String) async throws(HostError) -> [MemoryHit] {
        try await get(MemoryEnvelope.self, "/api/memory/query", query: ["q": query, "k": "20"]).results
    }

    func memoryPage(path: String, workspace: String, project: String) async throws(HostError) -> MemoryPage {
        try await get(MemoryPage.self, "/api/memory/page",
                      query: ["path": path, "workspace": workspace, "project": project])
    }

    func status() async throws(HostError) -> StatusPayload { try await get(StatusPayload.self, "/api/status") }

    /// 404 until the first /optimize scan has run.
    func optimizeLatest() async throws(HostError) -> OptimizeReport {
        try await get(OptimizeReport.self, "/api/optimize/latest")
    }

    /// 404 until job-radar has produced a report.
    func mergedOffers() async throws(HostError) -> MergedOffers {
        try await get(MergedOffers.self, "/api/jobsearch/merged")
    }

    func applications() async throws(HostError) -> Applications {
        try await get(Applications.self, "/api/jobsearch/applications")
    }

    func commands() async throws(HostError) -> [CommandSpec] {
        try await get(CommandsEnvelope.self, "/api/commands").commands
    }

    func briefs() async throws(HostError) -> [BriefSummary] {
        try await get(BriefsEnvelope.self, "/api/briefs").briefs
    }

    func brief(_ name: String) async throws(HostError) -> BriefDetail {
        try await get(BriefDetail.self, "/api/briefs/\(name)")
    }

    func conversations() async throws(HostError) -> ConversationIndex {
        try await get(ConversationIndex.self, "/api/conversations")
    }

    func conversation(_ id: String) async throws(HostError) -> ConversationDetail {
        try await get(ConversationDetail.self, "/api/conversations/\(id)")
    }

    // MARK: Control (Bearer)

    func decide(approvalID: String, approve: Bool) async throws(HostError) {
        let query = ["approval_id": approvalID, "decision": approve ? "approve" : "deny"]
        _ = try await send("/api/approvals", query: query)
    }

    func setKillSwitch(_ on: Bool) async throws(HostError) -> Bool {
        let data = try await send("/api/killswitch", query: ["state": on ? "true" : "false"])
        return try decode(KillSwitchEnvelope.self, data).killswitch
    }

    func resetBreaker() async throws(HostError) -> BreakerStatus {
        try decode(BreakerStatus.self, try await send("/api/breaker/reset"))
    }

    /// Returns the new `task_id`.
    func createTask(_ task: NewTask) async throws(HostError) -> String {
        let body: Data
        do { body = try JSONEncoder().encode(task) } catch { throw .decoding("encodage de la tâche") }
        return try decode(TaskIDEnvelope.self, try await send("/api/tasks", body: body)).taskId
    }

    /// Returns the task's new status (`cancelled`, `paused` or `queued`).
    func taskAction(id: String, action: TaskAction) async throws(HostError) -> String {
        try decode(TaskStatusEnvelope.self, try await send("/api/tasks/\(id)/\(action.rawValue)")).status
    }

    /// Starts the /optimize scan in the background (`started: false` when one already runs).
    func startScan() async throws(HostError) -> LaunchReply {
        try decode(LaunchReply.self, try await send("/api/optimize/run"))
    }

    /// Starts a job-radar run in the background.
    func runJobRadar() async throws(HostError) -> LaunchReply {
        try decode(LaunchReply.self, try await send("/api/jobsearch/run"))
    }

    /// Runs a command of the catalogue (spec §15.2); `.refused` carries the host's reason for a 400.
    /// `timeout` nil keeps the session's 5 s.
    func runCommand(
        _ name: String, params: [String: String], timeout: TimeInterval? = nil
    ) async throws(HostError) -> CommandLaunch {
        let body: Data
        do { body = try JSONEncoder().encode(["params": params]) } catch { throw .decoding("encodage de la commande") }
        return try decode(CommandLaunch.self, try await send("/api/commands/\(name)", body: body, timeout: timeout))
    }

    /// The host always stores a draft: a validated brief edited here needs a new validation.
    func saveBrief(_ name: String, text: String) async throws(HostError) {
        let body: Data
        do { body = try JSONEncoder().encode(["text": text]) } catch { throw .decoding("encodage du brief") }
        _ = try await send("/api/briefs/\(name)", body: body, method: "PUT")
    }

    /// Returns the sha256 the host journaled. With ``shown`` (the listed version's seal) the host
    /// answers 409 if the brief changed since it was listed: JT validates what he saw.
    func validateBrief(_ name: String, shown: String? = nil) async throws(HostError) -> String {
        var body: Data?
        if let shown {
            do { body = try JSONEncoder().encode(["sha256": shown]) } catch { throw .decoding("encodage du sceau") }
        }
        return try decode(BriefValidation.self, try await send("/api/briefs/\(name)/validate", body: body)).sha256
    }

    // The four calls below work on the host (a worktree, a turn, a merge, several launches): the slow-command
    // timeout, else a 5 s cut-off reads « injoignable » over work that went through.

    /// Project and mode are fixed for the conversation; the first message starts its session.
    func openConversation(project: String, mode: String, effort: String,
                          message: String) async throws(HostError) -> TurnStarted {
        let body = try Self.encoded(["project": project, "mode": mode, "effort": effort, "message": message],
                                    "de la conversation")
        return try decode(TurnStarted.self, try await send("/api/conversations", body: body,
                                                          timeout: Self.slowCommandTimeout))
    }

    func sendMessage(_ id: String, text: String) async throws(HostError) -> TurnStarted {
        let body = try Self.encoded(["text": text], "du message")
        return try decode(TurnStarted.self, try await send("/api/conversations/\(id)/messages", body: body,
                                                          timeout: Self.slowCommandTimeout))
    }

    /// The cards as JT left them; the host checks every field again (kernel/delegation.py). It creates, seals
    /// and launches each brief in this one call.
    func delegate(_ id: String, cards: [DelegationCard]) async throws(HostError) -> DelegationReply {
        let body = try Self.encoded(["cards": cards], "des cartes")
        return try decode(DelegationReply.self, try await send("/api/conversations/\(id)/delegate", body: body,
                                                              timeout: Self.slowCommandTimeout))
    }

    func promoteConversation(_ id: String) async throws(HostError) -> PromotionReply {
        try decode(PromotionReply.self, try await send("/api/conversations/\(id)/promote",
                                                       timeout: Self.slowCommandTimeout))
    }

    /// JSON in snake_case (`done_when`, `output_mode`), as the host reads it.
    private static func encoded<T: Encodable>(_ value: T, _ what: String) throws(HostError) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do { return try encoder.encode(value) } catch { throw .decoding("encodage \(what)") }
    }

    // MARK: Plumbing

    /// `timeout` nil keeps the session's 5 s.
    private func get<T: Decodable>(
        _ type: T.Type, _ path: String, query: [String: String] = [:], timeout: TimeInterval? = nil
    ) async throws(HostError) -> T {
        var request = makeRequest("GET", path, query: query)
        if let timeout { request.timeoutInterval = timeout }
        return try decode(type, try await perform(request))
    }

    private func send(
        _ path: String, query: [String: String] = [:], body: Data? = nil, method: String = "POST",
        timeout: TimeInterval? = nil
    ) async throws(HostError) -> Data {
        let secret: String?
        do { secret = try await token() } catch {
            logger.error("control token read failed: \(String(describing: error), privacy: .public)")
            throw .tokenUnavailable
        }
        guard let secret else { throw .tokenUnavailable }
        var request = makeRequest(method, path, query: query)
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        logger.notice("\(method, privacy: .public) \(path, privacy: .public)")
        return try await perform(request)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String]) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            // Sorted so requests are deterministic (tests compare query strings).
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
            // Foundation leaves a literal `+` raw and the host decodes it as a space (`q=C++`, a path
            // with a `+`); a space is already `%20`, so every `+` left here is a literal one.
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.percentEncodedQuery = components.percentEncodedQuery?
                    .replacingOccurrences(of: "+", with: "%2B")
                url = components.url ?? url
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func perform(_ request: URLRequest) async throws(HostError) -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) } catch {
            throw .unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw .unauthorized
        case 404: throw .notFound
        case 503:
            // 503 is also « harness facts unreadable » (brief validation): keep the host's reason.
            if let detail = Self.hostDetail(in: data) { throw .host(status, detail) }
            throw .controlDisabled
        case 400, 422: throw .refused(Self.hostDetail(in: data) ?? "requête refusée (\(status))")
        default:
            if let detail = Self.hostDetail(in: data) { throw .host(status, detail) }
            throw .http(status)
        }
    }

    /// FastAPI's `{"detail": "…"}`; a list (422), an HTML page or an empty text is not a reason.
    private static func hostDetail(in data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(DetailEnvelope.self, from: data) else { return nil }
        let detail = envelope.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(HostError) -> T {
        do { return try decoder.decode(type, from: data) } catch {
            throw .decoding(String(describing: type))
        }
    }
}

// Response envelopes of host.py (`{"pending": [...]}` etc.).
nonisolated private struct DetailEnvelope: Decodable { let detail: String }
nonisolated private struct OkEnvelope: Decodable { let ok: Bool }
nonisolated private struct KillSwitchEnvelope: Decodable { let killswitch: Bool }
nonisolated private struct PendingEnvelope: Decodable { let pending: [Approval] }
nonisolated private struct RunsEnvelope: Decodable { let runs: [RunSummary] }
nonisolated private struct JournalEnvelope: Decodable { let events: [JournalEvent] }
nonisolated private struct TasksEnvelope: Decodable { let tasks: [AgentTask] }
nonisolated private struct TaskIDEnvelope: Decodable { let taskId: String }
nonisolated private struct TaskStatusEnvelope: Decodable { let status: String }
nonisolated private struct VaultEnvelope: Decodable { let results: [VaultHit] }
nonisolated private struct MemoryEnvelope: Decodable { let results: [MemoryHit] }
nonisolated private struct CommandsEnvelope: Decodable { let commands: [CommandSpec] }
