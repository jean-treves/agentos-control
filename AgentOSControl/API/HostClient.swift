import Foundation
import os

/// Why a host call failed. Messages are shown to JT as is.
nonisolated enum HostError: Error, Equatable, Sendable, LocalizedError {
    /// Transport failure: host down, timeout, connection refused.
    case unreachable(String)
    /// No control token on this Mac (or read-only mode): the request was never sent.
    case tokenUnavailable
    /// 503: the host has no control token in its Keychain.
    case controlDisabled
    /// 401: the host rejected the token.
    case unauthorized
    case notFound
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Host injoignable (\(detail))."
        case .tokenUnavailable: "Jeton de contrôle introuvable dans le Trousseau : rien n'a été envoyé."
        case .controlDisabled: "Le host n'a pas de jeton de contrôle (503)."
        case .unauthorized: "Jeton de contrôle refusé par le host (401)."
        case .notFound: "Introuvable (404)."
        case .http(let status): "Erreur HTTP \(status)."
        case .decoding(let detail): "Réponse illisible (\(detail))."
        }
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
        _ path: String, query: [String: String] = [:], body: Data? = nil
    ) async throws(HostError) -> Data {
        let secret: String?
        do { secret = try await token() } catch {
            logger.error("control token read failed: \(String(describing: error), privacy: .public)")
            throw .tokenUnavailable
        }
        guard let secret else { throw .tokenUnavailable }
        var request = makeRequest("POST", path, query: query)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        logger.notice("POST \(path, privacy: .public)")
        return try await perform(request)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String]) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            // Sorted so requests are deterministic (tests compare query strings).
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
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
        case 503: throw .controlDisabled
        default: throw .http(status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(HostError) -> T {
        do { return try decoder.decode(type, from: data) } catch {
            throw .decoding(String(describing: type))
        }
    }
}

// Response envelopes of host.py (`{"pending": [...]}` etc.).
nonisolated private struct OkEnvelope: Decodable { let ok: Bool }
nonisolated private struct KillSwitchEnvelope: Decodable { let killswitch: Bool }
nonisolated private struct PendingEnvelope: Decodable { let pending: [Approval] }
nonisolated private struct RunsEnvelope: Decodable { let runs: [RunSummary] }
nonisolated private struct JournalEnvelope: Decodable { let events: [JournalEvent] }
nonisolated private struct TasksEnvelope: Decodable { let tasks: [AgentTask] }
nonisolated private struct TaskIDEnvelope: Decodable { let taskId: String }
nonisolated private struct TaskStatusEnvelope: Decodable { let status: String }
