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
      {"v":1,"seq":42,"ts":"2026-09-23T21:06:13.700Z","run_id":"run_0123456789abcdef0123456789abcdef",
       "task_id":null,"engine":null,"type":"approval.waiting","data":{
       "approval_id":"3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71","capability":"file_write",
       "target_excerpt":"README.md"},"prev_hash":"22","hash":"33"},
      {"v":1,"seq":43,"ts":"2026-09-23T21:06:14.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
       "task_id":"t_0a1b2c3d4e","engine":"claude","type":"approval.resolved",
       "data":["unexpected","array"],"prev_hash":"33","hash":"44"}]}
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
    static let commands = """
    {"commands":[
      {"name":"optimisation","title":"Optimisation","description":"Diagnostic du Mac","interactive":false,"params":[]},
      {"name":"passover","title":"Passover","description":"Déléguer","interactive":false,"params":[
        {"name":"brief","label":"Brief","kind":"choice","choices":["2026-09-28-sample.md"],"default":null,"required":true,"labels":{"2026-09-28-sample.md":"Échantillon"}},
        {"name":"at","label":"Quand","kind":"datetime","choices":null,"default":"2026-09-28T19:43:00+00:00","required":true}]},
      {"name":"pitch","title":"Pitch","description":"Jury","interactive":true,"params":[]}]}
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

    @Test func memorySearchesHitTheirRoutes() async throws {
        let vault = try await makeClient(body: #"{"query":"q","results":[{"source":"vault","path":"/v/a.md","snippet":"s","score":0.9,"method":"fts"}]}"#,
                                         recorder: recorder).vaultSearch("hermes chat")
        #expect(vault.first?.source == "vault")
        let hits = try await makeClient(body: #"{"query":"q","results":[{"path":"sessions/a.md","title":"T","snippet":"S","project":"p","workspace":"w","rank":1.5}]}"#,
                                        recorder: recorder).memoryQuery("hermes chat")
        #expect(hits.first?.workspace == "w" && hits.first?.rank == 1.5)
        let paths = await recorder.requests.map { "\($0.url?.path() ?? "")?\($0.url?.query() ?? "")" }
        #expect(paths == ["/api/memory/search?k=20&q=hermes%20chat", "/api/memory/query?k=20&q=hermes%20chat"])
    }

    @Test func memoryPageSendsPathWorkspaceAndProject() async throws {
        let page = try await makeClient(body: #"{"path":"sessions/a.md","title":"T","body":"corps"}"#, recorder: recorder)
            .memoryPage(path: "sessions/a.md", workspace: "default", project: "PyCharmMiscProject")
        #expect(page.title == "T" && page.body == "corps")
        let url = await recorder.requests.first?.url
        #expect(url?.path() == "/api/memory/page")
        #expect(url?.query() == "path=sessions/a.md&project=PyCharmMiscProject&workspace=default")
    }

    /// `URL.append(queryItems:)` leaves `+` raw and the host reads it as a space (`q=C++` searched "C  ").
    @Test func plusSignsInQueriesAreEscapedOthersKeepTheirForm() async throws {
        _ = try await makeClient(body: #"{"query":"q","results":[]}"#, recorder: recorder).vaultSearch("C++ & é #1 100%")
        _ = try await makeClient(body: #"{"path":"p","title":"T","body":"b"}"#, recorder: recorder)
            .memoryPage(path: "sessions/a+b.md", workspace: "default", project: "P Q")
        let queries = await recorder.requests.map { $0.url?.query() ?? "" }
        #expect(queries == [
            "k=20&q=C%2B%2B%20%26%20%C3%A9%20%231%20100%25",
            "path=sessions/a%2Bb.md&project=P%20Q&workspace=default",
        ])
    }

    @Test func storageAndJobsDecodeTheirLiveShapes() async throws {
        let disk = try await makeClient(body: #"{"disk":{"free_gb":77.7,"total_gb":460.4,"used_pct":83},"load":[1,2,3]}"#,
                                        recorder: recorder).status().disk
        #expect(disk?.usedPct == 83)
        let report = try await makeClient(body: #"{"generated_at":"2026-09-11T17:41:22+00:00","findings":[{"id":"f1","category":"disk","title":"~/Downloads occupies 2.4 GB","description":"d","command":null,"risk_level":"low","one_click_safe":false,"estimated_impact_mb":null}]}"#,
                                          recorder: recorder).optimizeLatest()
        #expect(report.findings.first?.estimatedImpactMb == nil && report.findings.first?.command == nil)
        let merged = try await makeClient(body: #"{"offers":[{"stars":2,"title":"Quant","company":"C","url":"https://example.invalid/o","why":"w","location":"Genève","country":"CH","posted":"2026-09-27","source":"pme","family":"quant","is_agency":false}],"offers_count":1,"report_date":"2026-09-28","producers":{"pme":1}}"#,
                                          recorder: recorder).mergedOffers()
        #expect(merged.offers.first?.stars == 2 && merged.reportDate == "2026-09-28")
        let apps = try await makeClient(body: #"{"total":0,"funnel":{"identified":0},"due":[],"schema_version":1}"#,
                                        recorder: recorder).applications()
        #expect(apps.total == 0 && apps.due?.isEmpty == true)
        let paths = await recorder.requests.map { $0.url?.path() ?? "" }
        #expect(paths == ["/api/status", "/api/optimize/latest", "/api/jobsearch/merged", "/api/jobsearch/applications"])
    }

    /// Ignored elements must still count: `due` is only shown as a number.
    @Test func dueFollowUpsAreCountedWhateverTheirContent() async throws {
        let apps = try await makeClient(body: #"{"total":3,"funnel":{},"due":[{"company":"A"},{"x":1},"odd"]}"#,
                                        recorder: recorder).applications()
        #expect(apps.due?.count == 3)
    }

    @Test func launchRoutesArePostsWithTheBearerAndReadTheirReply() async throws {
        let started = try await makeClient(body: #"{"started":true,"pid":4242}"#, recorder: recorder).startScan()
        #expect(started == LaunchReply(started: true, reason: nil))
        let refused = try await makeClient(body: #"{"started":false,"reason":"scan already running"}"#, recorder: recorder)
            .runJobRadar()
        #expect(refused == LaunchReply(started: false, reason: "scan already running"))
        let sent = await recorder.requests
        #expect(sent.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
                == ["POST /api/optimize/run", "POST /api/jobsearch/run"])
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        // No token on this Mac: the launch is refused locally, unsent.
        let recorder = recorder
        let noToken = HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil },
                                 transport: { request in
                                     await recorder.record(request)
                                     throw URLError(.notConnectedToInternet)
                                 })
        await #expect(throws: HostError.tokenUnavailable) { try await noToken.startScan() }
        #expect(await recorder.requests.count == 2)
    }

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
        #expect(events.map(\.seq) == [40, 41, 42, 43])
        #expect(events[0].data?.verdict == "ask")
        #expect(events[0].data?.rule == "ask.file_write")
        let stamp = try #require(events[0].date).timeIntervalSince1970
        #expect(abs(stamp - 1_790_197_572.017) < 0.001)
        #expect(events[1].engine == nil && events[1].runId == nil)
        #expect(events[2].data?.approvalId == "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71")
        #expect(events[3].data == nil)
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

    @Test func decodesGlanceWithMissingFields() async throws {
        let full = try await makeClient(
            body: #"{"offers":47,"jobs_date":"2026-09-28","reclaim_gb":3.1,"scan_date":"2026-09-11","cpu_24h":[]}"#,
            recorder: recorder).glance()
        #expect(full.offers == 47 && full.jobsDate == "2026-09-28" && full.reclaimGb == 3.1)
        let sent = await recorder.requests
        #expect(sent.first?.url?.path() == "/api/glance")
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
        let empty = try await makeClient(body: "{}", recorder: recorder).glance()
        #expect(empty.offers == nil && empty.scanDate == nil)
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

    @Test func decodesTheCommandCatalogue() async throws {
        let specs = try await makeClient(body: Fixture.commands, recorder: recorder).commands()
        #expect(specs.map(\.name) == ["optimisation", "passover", "pitch"])
        #expect(specs[1].params[0].choices == ["2026-09-28-sample.md"] && specs[1].params[0].defaultValue == nil)
        #expect(specs[1].params[0].labels == ["2026-09-28-sample.md": "Échantillon"] && specs[1].params[1].labels == nil)
        #expect(specs[1].params[1].defaultValue == "2026-09-28T19:43:00+00:00" && specs[2].interactive)
    }

    /// Label keys are the server's raw values (`accept_diffs`): the snake_case key strategy must not touch them.
    @Test func labelKeysKeepTheirSnakeCase() async throws {
        let body = #"{"commands":[{"name":"c","title":"C","description":"d","interactive":false,"params":[{"name":"mode","label":"Mode","kind":"choice","choices":["accept_diffs"],"default":"accept_diffs","required":true,"labels":{"accept_diffs":"Accepter les diffs"}}]}]}"#
        let spec = try await makeClient(body: body, recorder: recorder).commands()[0]
        #expect(spec.params[0].labels?["accept_diffs"] == "Accepter les diffs")
    }

    @Test func aBadRequestWithoutAStringDetailStillSaysRefused() async {
        let client = makeClient(status: 422, body: #"{"detail":[{"loc":["body"],"msg":"field required"}]}"#, recorder: recorder)
        await #expect(throws: HostError.refused("requête refusée (422)")) {
            try await client.runCommand("passover", params: [:])
        }
    }

    @Test func runCommandPostsTheParamsWithTheToken() async throws {
        let client = makeClient(
            body: #"{"command":"passover","task_ids":["t_1"],"run_ids":["r_1"],"result":null}"#, recorder: recorder)
        let launch = try await client.runCommand("passover", params: ["brief": "b.md", "mode": "pr"])
        #expect(launch.taskIds == ["t_1"] && launch.runIds == ["r_1"] && launch.result == nil)
        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path() == "/api/commands/passover")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: [String: String]]
        #expect(body == ["params": ["brief": "b.md", "mode": "pr"]])
    }

    @Test func aRefusalCarriesTheServerReason() async {
        let client = makeClient(status: 400, body: #"{"detail":"Brief : valeur hors liste"}"#, recorder: recorder)
        await #expect(throws: HostError.refused("Brief : valeur hors liste")) {
            try await client.runCommand("passover", params: [:])
        }
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

    /// 503 is two things: no control token (no reason to read) and a validation that cannot run
    /// (a reason the host gives): the second must not read « pas de jeton ».
    @Test func aServiceUnavailableKeepsTheHostsReason() async {
        let detail = "faits du harnais illisibles (config/harness_facts.yaml) : validation impossible"
        let client = makeClient(status: 503, body: #"{"detail":"\#(detail)"}"#, recorder: recorder)
        let error = await #expect(throws: HostError.self) { _ = try await client.validateBrief("2026-09-29-dm.md") }
        #expect(error == .host(503, detail))
        #expect(error?.localizedDescription == "\(detail) (HTTP 503).")
    }

    /// The host has already acted when `POST /api/commands/{name}` answers: a result value that is not a
    /// string must not turn a launched command into « réponse illisible » (and a second click).
    @Test func aLaunchResultWithNonStringValuesStillDecodes() async throws {
        let body = #"{"command":"promote","task_ids":[],"run_ids":[],"result":{"branch":"b","files_changed":3,"pushed":false,"ratio":0.5,"note":null,"paths":["a","b"]}}"#
        let launch = try await makeClient(body: body, recorder: recorder).runCommand("promote", params: [:])
        #expect(launch.result == ["branch": "b", "files_changed": "3", "pushed": "false", "ratio": "0.5",
                                  "paths": "(valeur non textuelle)"])
        #expect(launch.command == "promote")
    }

    /// The host explains its failures (`{"detail": "ai-memory : connection refused"}`): JT reads that,
    /// not a bare status.
    @Test func aFailureCarriesTheHostsOwnReason() async {
        let client = makeClient(status: 502, body: #"{"detail":"ai-memory : connection refused"}"#, recorder: recorder)
        let error = await #expect(throws: HostError.self) { _ = try await client.pendingApprovals() }
        #expect(error == .host(502, "ai-memory : connection refused"))
        #expect(error?.localizedDescription == "ai-memory : connection refused (HTTP 502).")
    }

    /// FastAPI's 422 carries a list, a proxy an HTML page, a bare 500 nothing: all stay a plain status.
    @Test(arguments: [#"{"detail":[{"loc":["query","q"],"msg":"field required"}]}"#, "{}", "<html>", #"{"detail":"  "}"#])
    func withoutAStringDetailItStaysAPlainHTTPError(body: String) async {
        let client = makeClient(status: 500, body: body, recorder: recorder)
        await #expect(throws: HostError.http(500)) { _ = try await client.pendingApprovals() }
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
