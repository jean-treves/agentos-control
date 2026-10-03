import Foundation
import Testing
@testable import AgentOSControl

/// The host as the Ménage sheet meets it: catalogue, proposal, then `menage-appliquer` answering from a
/// script (one answer per call, the last one repeats). Records every request and every Touch ID prompt.
nonisolated private struct MenageHost {
    static let proposalBody = #"{"command":"menage","task_ids":[],"run_ids":[],"result":{"proposal":"0123456789ab","count":"2","total_mb":"412.5","items":"worktree /w/run-1 (400.0 Mo) — fini\ntmp /h/tmp/x (12.5 Mo)","kept":"1 gardé(s) : relecture non promue"}}"#
    static let appliedBody = #"{"command":"menage-appliquer","task_ids":[],"run_ids":[],"result":{"applied":"2","skipped":"0","trash":"/home/_a-trier/agentos-menage-x","reasons":""}}"#
    static let gone = #"{"detail":"proposition introuvable ou déjà appliquée"}"#
    private static let catalogue = #"{"commands":[{"name":"menage","title":"Ménage : proposition","description":"d","interactive":false,"params":[]},{"name":"menage-appliquer","title":"Ménage : appliquer","description":"d","interactive":false,"params":[{"name":"proposal","label":"Proposition","kind":"choice","choices":["0123456789ab"],"default":null,"required":true}]}]}"#

    let recorder = RequestRecorder()
    let prompts = ReasonRecorder()
    let applyCalls = CallCounter()

    /// `applyAnswers`: status and body of the 1st, 2nd… `menage-appliquer`.
    @MainActor func model(
        present: Bool = true, touchID: FirstCallGate? = nil, catalogue: String = MenageHost.catalogue,
        applyAnswers: [(Int, String)] = [(200, MenageHost.appliedBody)]
    ) -> ControlModel {
        let (recorder, prompts, applyCalls) = (recorder, prompts, applyCalls)
        let client = HostClient(
            baseURL: URL(string: "http://127.0.0.1:3107")!,
            token: { "test-token" },
            transport: { request in
                await recorder.record(request)
                let path = request.url?.path() ?? ""
                var (status, body) = (200, "{}")
                switch (request.httpMethod ?? "", path) {
                case ("GET", "/api/commands"): body = catalogue
                case ("POST", "/api/commands/menage"): body = MenageHost.proposalBody
                case ("POST", "/api/commands/menage-appliquer"):
                    let call = await applyCalls.next()
                    (status, body) = applyAnswers[min(call, applyAnswers.count - 1)]
                default: status = 404
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            })
        return ControlModel(
            client: client,
            presence: HumanPresence { reason in
                await prompts.add(reason)
                await touchID?.pass()
                return present
            },
            notifier: nil, socket: nil)
    }

    nonisolated func posts() async -> [URLRequest] { await recorder.requests.filter { $0.httpMethod == "POST" } }
}

actor CallCounter {
    private var calls = 0
    /// 0 for the first call, 1 for the second…
    func next() -> Int {
        defer { calls += 1 }
        return calls
    }
}

/// What JT's sheet does, driven through the same `CleanupFlow` the view holds (F1, F7).
@MainActor @Suite struct CleanupFlowTests {
    private func proposed(_ model: ControlModel) async throws -> CleanupFlow {
        let flow = CleanupFlow()
        await flow.propose(using: model)
        _ = try #require(flow.proposal)
        return flow
    }

    /// `menage` waits for Haiku (up to 90 s) and the size of every candidate: not the session's 5 s.
    @Test func proposingWaitsLongerThanTheSessionDefault() async throws {
        let host = MenageHost()
        let flow = try await proposed(host.model())
        let request = try #require(await host.posts().first)
        #expect(request.url?.path() == "/api/commands/menage")
        #expect(request.timeoutInterval == HostClient.slowCommandTimeout && request.timeoutInterval > 90)
        #expect(flow.proposal?.id == "0123456789ab" && flow.problem == nil)
    }

    /// F1: the host moves a dozen worktrees for several seconds; the 5 s session timeout cut the reply and the
    /// sheet said « Host injoignable » over a ménage that had happened.
    @Test func applyingWaitsLongerThanTheSessionDefaultAndAsksTouchIDFirst() async throws {
        let host = MenageHost()
        let model = host.model()
        let flow = try await proposed(model)
        await flow.apply(using: model)
        let apply = try #require(await host.posts().last)
        #expect(apply.url?.path() == "/api/commands/menage-appliquer" && apply.httpMethod == "POST")
        #expect(apply.timeoutInterval == HostClient.slowCommandTimeout)
        #expect(apply.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(try JSONDecoder().decode([String: [String: String]].self, from: try #require(apply.httpBody))
                == ["params": ["proposal": "0123456789ab"]])  // the id of the list JT is looking at
        #expect(await host.prompts.values == ["lancer « Ménage : appliquer »"])
        #expect(flow.report == "2 appliqué(s), 0 ignoré(s). Rangé dans /home/_a-trier/agentos-menage-x.")
        #expect(flow.problem == nil)
    }

    /// The report is JT's only trace of where the files went: a second click must not replace it (E2E 35).
    @Test func aSecondApplyIsRefusedBesideTheFirstReport() async throws {
        let host = MenageHost()
        let model = host.model(applyAnswers: [(200, MenageHost.appliedBody), (400, MenageHost.gone)])
        let flow = try await proposed(model)
        await flow.apply(using: model)
        let report = try #require(flow.report)
        await flow.apply(using: model)
        #expect(flow.report == report)
        #expect(flow.problem == "Refusé par le host : proposition introuvable ou déjà appliquée")
        #expect(await host.prompts.values.count == 2)  // the second click did ask Touch ID, as the host decides
    }

    /// A proposal that expired (a newer one was made) answers the same refusal: shown, nothing applied.
    @Test func anExpiredProposalIsShownAsRefusedAndKeepsTheList() async throws {
        let host = MenageHost()
        let model = host.model(applyAnswers: [(400, MenageHost.gone)])
        let flow = try await proposed(model)
        await flow.apply(using: model)
        #expect(flow.report == nil)
        #expect(flow.problem == "Refusé par le host : proposition introuvable ou déjà appliquée")
        #expect(flow.proposal?.id == "0123456789ab")
    }

    /// A refusal that is gone once the next attempt goes through.
    @Test func aLaterSuccessClearsTheRefusal() async throws {
        let host = MenageHost()
        let model = host.model(applyAnswers: [(400, MenageHost.gone), (200, MenageHost.appliedBody)])
        let flow = try await proposed(model)
        await flow.apply(using: model)
        await flow.apply(using: model)
        #expect(flow.problem == nil && flow.report != nil)
    }

    @Test func withoutTouchIDNothingIsApplied() async throws {
        let host = MenageHost()
        let model = host.model(present: false)
        let flow = try await proposed(model)
        await flow.apply(using: model)
        #expect(await host.posts().count == 1)  // the proposal only
        #expect(flow.problem == ControlModel.notConfirmed && flow.report == nil)
    }

    /// Two clicks while Touch ID is open send one command.
    @Test func aSecondClickDuringTouchIDDoesNothing() async throws {
        let host = MenageHost()
        let gate = FirstCallGate()
        let model = host.model(touchID: gate)
        let flow = try await proposed(model)
        let first = Task { await flow.apply(using: model) }
        #expect(await eventually { await gate.arrivals == 1 })
        #expect(flow.applying)
        await flow.apply(using: model)
        await gate.open()
        await first.value
        #expect(await host.prompts.values.count == 1)
        #expect(await host.posts().filter { $0.url?.path() == "/api/commands/menage-appliquer" }.count == 1)
        #expect(!flow.applying)
    }

    @Test func aCatalogueWithoutTheCommandSaysSo() async throws {
        let host = MenageHost()
        let model = host.model(catalogue: #"{"commands":[]}"#)
        let flow = try await proposed(model)
        await flow.apply(using: model)
        #expect(flow.problem == "commande « menage-appliquer » absente du host")
        #expect(await host.posts().count == 1)
    }

    @Test func aReplyWithoutAProposalIsExplained() async {
        let client = HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { "t" }, transport: { request in
            (Data(#"{"command":"menage","task_ids":[],"run_ids":[],"result":{}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let flow = CleanupFlow()
        await flow.propose(using: ControlModel(client: client, presence: HumanPresence { _ in true }, notifier: nil, socket: nil))
        #expect(flow.proposal == nil && flow.problem == "Réponse du host sans proposition.")
        #expect(!flow.canApply)
    }
}
