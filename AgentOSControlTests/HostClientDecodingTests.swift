import Foundation
import Testing
@testable import AgentOSControl

/// Synthetic fixtures: shapes copied from live host-v1 GETs (2026-09-23), every value invented.
enum Fixture {
    static let pending = """
    {"pending":[
      {"id":"3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71","ts":1790000000,"capability":"file_write",
       "target":"README.md (append one line)","run_id":"8d1e4b2a-5c6f-4a7b-9e0d-1f2a3b4c5d6e","timeout_at":1790000300},
      {"id":"b7c8d9e0-1f2a-4b3c-8d4e-5f6a7b8c9d0e","ts":1790000010,"capability":null,"target":null,
       "run_id":null,"timeout_at":1790000310}]}
    """
    static let runs = """
    {"runs":[
      {"run_id":"run_0123456789abcdef0123456789abcdef","prompt":"Summarise the sample file",
       "source":"task:t_0a1b2c3d4e","status":"running","created_at":1790000000,"updated_at":1790000042},
      {"run_id":"5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d","prompt":"Say hello","source":"schedule",
       "status":"completed","created_at":1789990000,"updated_at":1789990100}]}
    """
    static let runDetail = """
    {"run_id":"run_0123456789abcdef0123456789abcdef","prompt":"Summarise the sample file",
     "source":"task:t_0a1b2c3d4e","status":"completed","output":"Done.","created_at":1790000000,
     "updated_at":1790000042,"events":[
      {"seq":1,"ts":1790000001,"event":"message.delta","data":{"delta":"Hel","event":"message.delta",
       "run_id":"run_0123456789abcdef0123456789abcdef","timestamp":1790000001.5}},
      {"seq":2,"ts":1790000002,"event":"tool.started","data":"plain text payload"}]}
    """
    static let journal = """
    {"events":[
      {"v":1,"seq":40,"ts":"2026-09-23T21:06:12.017Z","run_id":"run_0123456789abcdef0123456789abcdef",
       "task_id":"t_0a1b2c3d4e","engine":"claude","type":"decision","data":{"capability":"file_write",
       "decider":"policy","hook_ms":1.5,"profile":"ask","reason":"ask rule matched","rule":"ask.file_write",
       "target_digest":"sha256:00ff","target_excerpt":"README.md","tool":"Edit","verdict":"ask","waited_ms":0},
       "prev_hash":"00","hash":"11"},
      {"v":1,"seq":41,"ts":"2026-09-23T21:06:13.500Z","run_id":null,"task_id":"t_0a1b2c3d4e","engine":null,
       "type":"health","data":{"detail":"ok","paused":"no","preflight":"ok"},"prev_hash":"11","hash":"22"},
      {"v":1,"seq":42,"ts":"2026-09-23T21:06:14.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
       "task_id":"t_0a1b2c3d4e","engine":"claude","type":"approval.resolved",
       "data":["unexpected","array"],"prev_hash":"22","hash":"33"}]}
    """
    static let tasks = """
    {"tasks":[
      {"task_id":"t_0a1b2c3d4e","title":"Sample task","prompt":"Do the sample thing","project":"quant/sample",
       "engine":"claude","profile":"ask","schedule":"once","revision":1,"next_run_at":null,"priority":2,
       "budget":{"max_tool_calls":3},"status":"paused","paused_reason":"approval_expired","source":"cli",
       "source_digest":null,"created_at":"2026-09-19T10:00:00.123456+00:00","updated_at":"2026-09-19T10:05:00+00:00"},
      {"task_id":"v_0123456789ab","title":"Vault task","prompt":"Another sample","project":"",
       "engine":"hermes","profile":"explore","schedule":"every:1h","revision":2,"next_run_at":null,"priority":2,
       "budget":{"max_tool_calls":"3"},"status":"queued","paused_reason":null,"source":"vault:inbox.md#L1",
       "source_digest":"abc","created_at":"2026-09-20T08:00:00+00:00","updated_at":"2026-09-20T08:00:00+00:00"}]}
    """
    static let breakerClosed = """
    {"consecutive_failures":0,"opened_at":null,"run_starts":[1790000000.5,1790000100.25],"can_launch":true,"reason":""}
    """
    static let breakerOpen = """
    {"consecutive_failures":3,"opened_at":1790000200.0,"run_starts":[],"can_launch":false,"reason":"breaker open"}
    """
    static let deepHealth = """
    {"ok":false,"generated_at":"2026-09-23T23:01:02+0200","checks":[
      {"name":"disk","ok":true,"detail":"120 GB free"},{"name":"ollama","ok":false,"detail":"connection refused"}]}
    """
}

/// Records every request a HostClient sends, so tests can prove what did (not) leave the app.
actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

func makeClient(
    status: Int = 200, body: String = "{}", token: String? = "test-token", recorder: RequestRecorder
) -> HostClient {
    HostClient(
        baseURL: URL(string: "http://127.0.0.1:3107")!,
        token: { token },
        transport: { request in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
}

@Suite struct HostClientDecodingTests {
    let recorder = RequestRecorder()

    @Test func decodesPendingApprovalsWithNullableFields() async throws {
        let approvals = try await makeClient(body: Fixture.pending, recorder: recorder).pendingApprovals()
        #expect(approvals.count == 2)
        #expect(approvals[0].id == "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71")
        #expect(approvals[0].capability == "file_write")
        #expect(approvals[0].timeoutAt == 1_790_000_300)
        #expect(approvals[1].capability == nil && approvals[1].runId == nil)
        let sent = await recorder.requests
        #expect(sent.first?.url?.path() == "/api/approvals/pending")
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func decodesRunsAndExtractsTaskID() async throws {
        let runs = try await makeClient(body: Fixture.runs, recorder: recorder).runs(limit: 20)
        #expect(runs.map(\.isRunning) == [true, false])
        #expect(runs[0].taskId == "t_0a1b2c3d4e")
        #expect(runs[1].taskId == nil)
        #expect(await recorder.requests.first?.url?.query() == "limit=20")
    }

    @Test func decodesRunDetailWhateverTheEventPayload() async throws {
        let run = try await makeClient(body: Fixture.runDetail, recorder: recorder)
            .run(id: "run_0123456789abcdef0123456789abcdef", after: 7)
        #expect(run.status == "completed")
        #expect(run.output == "Done.")
        #expect(run.events.map(\.seq) == [1, 2])
        let url = await recorder.requests.first?.url
        #expect(url?.path() == "/api/runs/run_0123456789abcdef0123456789abcdef")
        #expect(url?.query() == "after=7")
    }

    @Test func decodesJournalAndKeepsEventsWithOddPayloads() async throws {
        let events = try await makeClient(body: Fixture.journal, recorder: recorder)
            .journal(afterSeq: 39, runID: "run_0123456789abcdef0123456789abcdef")
        #expect(events.map(\.seq) == [40, 41, 42])
        #expect(events[0].data?.verdict == "ask")
        #expect(events[0].data?.rule == "ask.file_write")
        let stamp = try #require(events[0].date).timeIntervalSince1970
        #expect(abs(stamp - 1_790_197_572.017) < 0.001)
        #expect(events[1].engine == nil && events[1].runId == nil)
        #expect(events[2].data == nil)
        #expect(await recorder.requests.first?.url?.query()
            == "after_seq=39&run_id=run_0123456789abcdef0123456789abcdef")
    }

    @Test func journalWithoutRunIDOmitsTheParameter() async throws {
        _ = try await makeClient(body: #"{"events":[]}"#, recorder: recorder).journal(afterSeq: 0, runID: nil)
        #expect(await recorder.requests.first?.url?.query() == "after_seq=0")
    }

    @Test func decodesTasksAndToleratesAMalformedBudget() async throws {
        let tasks = try await makeClient(body: Fixture.tasks, recorder: recorder).tasks()
        #expect(tasks.map(\.taskId) == ["t_0a1b2c3d4e", "v_0123456789ab"])
        #expect(tasks[0].budget?.maxToolCalls == 3)
        #expect(tasks[0].pausedReason == "approval_expired")
        #expect(tasks[1].budget?.maxToolCalls == nil)
        #expect(tasks[0].created != nil)
    }

    @Test func decodesBreakerBothWays() async throws {
        let closed = try await makeClient(body: Fixture.breakerClosed, recorder: recorder).breaker()
        #expect(closed.canLaunch && closed.openedAt == nil)
        let open = try await makeClient(body: Fixture.breakerOpen, recorder: recorder).breaker()
        #expect(!open.canLaunch && open.consecutiveFailures == 3 && open.reason == "breaker open")
    }

    @Test func decodesDeepHealthKillSwitchAndHealth() async throws {
        let deep = try await makeClient(body: Fixture.deepHealth, recorder: recorder).deepHealth()
        #expect(!deep.ok)
        #expect(deep.checks.map(\.name) == ["disk", "ollama"])
        #expect(deep.generated != nil)
        #expect(try await makeClient(body: #"{"killswitch":false}"#, recorder: recorder).killSwitch() == false)
        #expect(try await makeClient(body: #"{"ok":true}"#, recorder: recorder).health())
    }

    @Test func onlyDeepHealthWaitsLongerThanTheSessionTimeout() async throws {
        _ = try await makeClient(body: Fixture.deepHealth, recorder: recorder).deepHealth()
        _ = try await makeClient(body: #"{"ok":true}"#, recorder: recorder).health()
        let sent = await recorder.requests
        #expect(sent.map { $0.url?.path() } == ["/api/health/deep", "/api/health"])
        // URLSession applies its own 5 s unless the request sets a value (measured 2026-09-25: an
        // explicit 15 s answered after 8 s, the untouched default of 60 timed out at 5 s).
        let untouched = URLRequest(url: try #require(sent[1].url)).timeoutInterval
        // Hermès then Ollama at 4 s each: a slow probe must not read as "host unreachable".
        #expect(sent[0].timeoutInterval != untouched && sent[0].timeoutInterval >= 15)
        #expect(sent[1].timeoutInterval == untouched)
    }

    @Test(arguments: [(true, "approve"), (false, "deny")])
    func decideSendsQueryParamsAndBearer(approve: Bool, decision: String) async throws {
        let client = makeClient(body: #"{"status":"ok","decision":"\#(decision)"}"#, recorder: recorder)
        try await client.decide(approvalID: "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71", approve: approve)
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/approvals")
        #expect(request.url?.query() == "approval_id=3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71&decision=\(decision)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func controlRoutesHitTheContractPaths() async throws {
        let client = makeClient(body: Fixture.breakerClosed, recorder: recorder)
        _ = try await client.resetBreaker()
        let killClient = makeClient(body: #"{"killswitch":true}"#, recorder: recorder)
        #expect(try await killClient.setKillSwitch(true))
        let actionClient = makeClient(body: #"{"task_id":"t_0a1b2c3d4e","status":"paused"}"#, recorder: recorder)
        #expect(try await actionClient.taskAction(id: "t_0a1b2c3d4e", action: .pause) == "paused")
        let sent = await recorder.requests
        #expect(sent.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")?\($0.url?.query() ?? "")" } == [
            "POST /api/breaker/reset?",
            "POST /api/killswitch?state=true",
            "POST /api/tasks/t_0a1b2c3d4e/pause?",
        ])
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    @Test func createTaskPostsTheTaskInBody() async throws {
        let client = makeClient(body: #"{"task_id":"t_9f8e7d6c5b"}"#, recorder: recorder)
        let draft = NewTask(title: "Sample", prompt: "Do it", project: "quant/sample", engine: "claude", profile: "ask")
        #expect(try await client.createTask(draft) == "t_9f8e7d6c5b")
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.path() == "/api/tasks")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["title": "Sample", "prompt": "Do it", "project": "quant/sample",
                         "engine": "claude", "profile": "ask"])
    }

    @Test func missingTokenSendsNothing() async throws {
        let client = makeClient(token: nil, recorder: recorder)
        await #expect(throws: HostError.tokenUnavailable) {
            try await client.decide(approvalID: "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71", approve: true)
        }
        #expect(await recorder.requests.isEmpty)
    }

    @Test(arguments: [(401, HostError.unauthorized), (503, .controlDisabled), (404, .notFound), (500, .http(500))])
    func mapsHTTPStatuses(status: Int, expected: HostError) async {
        let client = makeClient(status: status, recorder: recorder)
        await #expect(throws: expected) { try await client.setKillSwitch(false) }
    }

    @Test func mapsTransportFailureAndBadJSON() async throws {
        let down = HostClient(
            baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil },
            transport: { _ in throw URLError(.cannotConnectToHost) })
        let transportError = await #expect(throws: HostError.self) { _ = try await down.health() }
        guard case .unreachable = transportError else {
            Issue.record("expected .unreachable, got \(String(describing: transportError))")
            return
        }
        let garbled = makeClient(body: "<html>", recorder: recorder)
        let decodingError = await #expect(throws: HostError.self) { _ = try await garbled.pendingApprovals() }
        guard case .decoding = decodingError else {
            Issue.record("expected .decoding, got \(String(describing: decodingError))")
            return
        }
    }

    @Test func parsesSocketMessages() {
        #expect(SocketMessage.parse(#"{"type":"approval_resolved","id":"abc","decision":"approve"}"#)
            == .approvalResolved(id: "abc", approved: true))
        #expect(SocketMessage.parse(#"{"type":"approval_resolved","id":"abc","decision":"deny"}"#)
            == .approvalResolved(id: "abc", approved: false))
        #expect(SocketMessage.parse(#"{"type":"killswitch","state":true}"#) == .killSwitch(true))
        #expect(SocketMessage.parse(#"{"type":"approval_resolved","id":"abc","decision":"maybe"}"#) == nil)
        #expect(SocketMessage.parse(#"{"type":"something_new"}"#) == nil)
        #expect(SocketMessage.parse("not json") == nil)
    }

    @Test func socketURLSwapsTheScheme() {
        #expect(ApprovalsSocket.socketURL(for: URL(string: "http://127.0.0.1:3107")!).absoluteString
            == "ws://127.0.0.1:3107/ws/approvals")
    }
}
