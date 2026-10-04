import Foundation
import Testing
@testable import AgentOSControl

private let utc = TimeZone(identifier: "UTC")!

/// Counts the Touch ID prompts a test sees.
private actor Prompts {
    private(set) var reasons: [String] = []
    func ask(_ reason: String) { reasons.append(reason) }
}

@Suite struct ConversationTests {
    let recorder = RequestRecorder()

    static let index = """
    {"conversations":[{"id":"0f0e0d0c-0b0a-4908-8706-050403020100","title":"Tests DM","project":"quant/x","mode":"read","turns":2,"busy":false}],
     "options":{"projects":["quant/x"],"modes":{"read":"Lecture + délégation","modify":"Lecture, modification + délégation"},
                "output_modes":{"diagnostic":"Diagnostic","pr":"Essai + PR","yolo":"YOLO"},
                "agentic_modes":{"accept_diffs":"Accepter les diffs","auto":"Auto"},
                "executor_models":["auto:smart"],"efforts":["low","medium","high","xhigh","max"]},
     "quota":{"five_hour_utilization":0.86,"five_hour_resets_at":1790000000,"state":"warn"}}
    """

    /// `conversations.detail`: `asdict(Conversation)` plus `busy` and `quota`, cards as `delegation.card` leaves them.
    static let detail = """
    {"id":"0f0e0d0c-0b0a-4908-8706-050403020100","project":"quant/x","mode":"modify","title":"Tests DM",
     "created_at":"2026-10-04T10:00:00+00:00","effort":"medium","turns":2,
     "worktree":"/Users/jean/.local/share/agentos/worktrees/0f0e0d0c/0f0e0d0c","last_status":"completed","retry_at":null,
     "cards":[{"title":"Test DM","project":"quant/x","goal":"Ajouter le test.\\nSans toucher le reste.","context":"",
               "done_when":"pytest vert","verify":"uv run pytest -q","output_mode":"pr","agentic_mode":"accept_diffs",
               "executor_model":"auto:smart","sonnet_effort":"medium"}],
     "cards_error":"carte 2 : le brief n'a pas de verify:","busy":true,
     "quota":{"five_hour_utilization":0.5,"five_hour_resets_at":null,"state":"ok"}}
    """

    static let options = ConversationOptions(
        projects: ["quant/x"], modes: ["read": "Lecture + délégation"],
        outputModes: ["diagnostic": "Diagnostic", "pr": "Essai + PR", "yolo": "YOLO"],
        agenticModes: ["accept_diffs": "Accepter les diffs", "auto": "Auto"],
        executorModels: ["auto:smart"], efforts: ["low", "medium", "high"])

    static let card = DelegationCard(
        title: "Test DM", project: "quant/x", goal: "Ajouter le test.", context: "", doneWhen: "pytest vert",
        verify: "uv run pytest -q", outputMode: "pr", agenticMode: "accept_diffs", executorModel: "auto:smart",
        sonnetEffort: "medium")

    static func card(_ title: String, outputMode: String = "pr") -> DelegationCard {
        var copy = card
        copy.title = title
        copy.outputMode = outputMode
        return copy
    }

    @MainActor static func model(_ recorder: RequestRecorder, body: String = "{}",
                                 presence: HumanPresence = HumanPresence { _ in true }) -> ControlModel {
        ControlModel(client: makeClient(body: body, recorder: recorder), presence: presence, notifier: nil, socket: nil)
    }

    // MARK: Host shapes

    @Test func decodesTheIndexAndKeepsTheChoiceKeys() async throws {
        let index = try await makeClient(body: Self.index, recorder: recorder).conversations()
        #expect(index.conversations.first?.mode == "read" && index.options.projects == ["quant/x"])
        // Keys are values sent back to the host: never camel-cased by the snake_case strategy.
        #expect(index.options.agenticModes["accept_diffs"] == "Accepter les diffs")
        #expect(index.quota.state == "warn" && index.quota.line == "quota 5 h à 86 % : chaque message le consomme")
    }

    @Test func decodesTheDetailTheHostSends() async throws {
        let detail = try await makeClient(body: Self.detail, recorder: recorder).conversation("c1")
        #expect(detail.busy && detail.mode == "modify" && detail.worktree?.hasSuffix("/0f0e0d0c") == true)
        #expect(detail.cards.first?.doneWhen == "pytest vert" && detail.cards.first?.executorModel == "auto:smart")
        #expect(detail.cards.first?.goal == "Ajouter le test.\nSans toucher le reste.")
        #expect(detail.cardsError == "carte 2 : le brief n'a pas de verify:")
        #expect(detail.quota.state == "ok" && detail.quota.fiveHourResetsAt == nil)
        #expect(await recorder.requests.first?.url?.path() == "/api/conversations/c1")
    }

    @Test func cardsFromTheHostAreCleanedAndTheDefaultsFilled() throws {
        let raw = #"{"title":"T‮evil","project":"quant/x","goal":"g\u001B[31m","done_when":"d","output_mode":"pr","agentic_mode":"auto","executor_model":"auto:smart"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let card = try decoder.decode(DelegationCard.self, from: Data(raw.utf8))
        #expect(card.title == "T evil" && card.goal == "g [31m")
        #expect(card.context == "" && card.verify == "" && card.sonnetEffort == "medium")
    }

    @Test func quotaLinesAndTheResetTime() {
        func quota(_ used: Double?, _ resets: Double?, _ state: String) -> QuotaInfo {
            QuotaInfo(fiveHourUtilization: used, fiveHourResetsAt: resets, state: state)
        }
        #expect(quota(nil, nil, "ok").line == "quota 5 h inconnu")
        #expect(quota(0.5, nil, "ok").line == "quota 5 h : 50 %")
        #expect(quota(1, 1_790_000_000, "exhausted").line == "quota 5 h épuisé (100 %) : rien n'est envoyé")
        // 1790000000 is 2026-09-21 14:13:20 UTC; a window that already reset says nothing.
        let spent = quota(1, 1_790_000_000, "exhausted")
        #expect(spent.resetNote(now: Date(timeIntervalSince1970: 1_789_990_000), in: utc) == "remise à zéro à 14:13")
        #expect(spent.resetNote(now: Date(timeIntervalSince1970: 1_790_000_001), in: utc) == nil)
        #expect(quota(0.2, nil, "ok").resetNote(now: Date(), in: utc) == nil)
    }

    // MARK: Requests

    @Test func openingPostsProjectModeAndFirstMessageWithTheToken() async throws {
        let client = makeClient(body: #"{"id":"c1","turn_id":"t1"}"#, recorder: recorder)
        let started = try await client.openConversation(project: "quant/x", mode: "modify", effort: "high",
                                                        message: "Bonjour")
        #expect(started.id == "c1" && started.turnId == "t1")
        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path() == "/api/conversations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["project": "quant/x", "mode": "modify", "effort": "high", "message": "Bonjour"])
    }

    @Test func aMessageIsSentWithTheTokenAndOnlyItsText() async throws {
        let started = try await makeClient(body: #"{"id":"c1","turn_id":"t2"}"#, recorder: recorder)
            .sendMessage("c1", text: "Encore")
        #expect(started.turnId == "t2")
        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path() == "/api/conversations/c1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["text": "Encore"])
    }

    @Test func delegationSendsTheEditedCardsInSnakeCase() async throws {
        let reply = #"{"delegated":[{"brief":"2026-09-30-test-dm.md","sha256":"sha256:ab","task_ids":["t_1"],"run_ids":[]}]}"#
        let delegated = try await makeClient(body: reply, recorder: recorder).delegate("c1", cards: [Self.card])
        #expect(delegated.delegated.first?.taskIds == ["t_1"])
        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path() == "/api/conversations/c1/delegate")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: [[String: String]]]
        #expect(body?["cards"]?.first?["done_when"] == "pytest vert")
        #expect(body?["cards"]?.first?["agentic_mode"] == "accept_diffs")
    }

    /// A card never widens a mandate: exactly the host's ten fields leave the app (kernel/delegation.FIELDS).
    @Test func aCardCarriesExactlyTheHostsFields() async throws {
        _ = try? await makeClient(body: #"{"delegated":[]}"#, recorder: recorder).delegate("c1", cards: [Self.card])
        let request = try #require(await recorder.requests.first)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: [[String: String]]]
        #expect(Set(body?["cards"]?.first?.keys.map { $0 } ?? [])
                == ["title", "project", "goal", "context", "done_when", "verify", "output_mode", "agentic_mode",
                    "executor_model", "sonnet_effort"])
    }

    @Test func promotionPostsToItsRoute() async throws {
        let reply = try await makeClient(body: #"{"branch":"work","head":"abc1234"}"#, recorder: recorder)
            .promoteConversation("c1")
        #expect(reply.branch == "work" && reply.head == "abc1234")
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.path() == "/api/conversations/c1/promote")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    /// Every call that works on the host (a worktree, a turn, a merge, several launches) waits as long as the
    /// slowest command: a timeout would say « injoignable » over work that went through.
    @Test func callsThatActWaitAsLongAsASlowCommand() async throws {
        let client = makeClient(body: #"{"id":"c1","turn_id":"t","delegated":[],"branch":"b","head":"h"}"#, recorder: recorder)
        _ = try await client.openConversation(project: "quant/x", mode: "read", effort: "medium", message: "a")
        _ = try await client.sendMessage("c1", text: "b")
        _ = try await client.delegate("c1", cards: [Self.card])
        _ = try await client.promoteConversation("c1")
        let timeouts = await recorder.requests.map(\.timeoutInterval)
        #expect(timeouts == Array(repeating: HostClient.slowCommandTimeout, count: 4))
    }

    @Test func aRefusedDelegationReadsAsTheHostsReason() async {
        let client = makeClient(status: 400, body: #"{"detail":"carte 1 : le brief n'a pas de verify:"}"#,
                                recorder: recorder)
        await #expect(throws: HostError.refused("carte 1 : le brief n'a pas de verify:")) {
            try await client.delegate("c1", cards: [Self.card])
        }
    }

    // MARK: Touch ID

    @MainActor @Test func delegationAndPromotionWithoutPresenceSendNothing() async {
        let model = ControlModel(client: makeClient(recorder: recorder),
                                 presence: HumanPresence { _ in false }, notifier: nil, socket: nil)
        #expect(await model.delegate("c1", cards: [Self.card]) == nil)
        #expect(await model.promoteConversation("c1") == nil)
        #expect(await recorder.requests.isEmpty)
    }

    @MainActor @Test func theTouchIDPromptNamesTheNumberOfBriefs() async {
        let prompts = Prompts()
        let model = Self.model(recorder, body: #"{"delegated":[]}"#, presence: HumanPresence { await prompts.ask($0); return true })
        _ = await model.delegate("c1", cards: [Self.card("A"), Self.card("B")])
        #expect(await prompts.reasons == ["lancer 2 brief(s) délégué(s)"])
        #expect(DelegationReview.touchIDReason(count: 1) == "lancer 1 brief(s) délégué(s)")
    }

    /// The host will only accept diagnostic and pr; a card that says otherwise is not even offered Touch ID.
    @MainActor @Test func aYoloCardIsRefusedBeforeTouchIDAndNothingIsSent() async {
        let prompts = Prompts()
        let model = Self.model(recorder, presence: HumanPresence { await prompts.ask($0); return true })
        #expect(await model.delegate("c1", cards: [Self.card("A"), Self.card("B", outputMode: "yolo")]) == nil)
        #expect(await model.delegate("c1", cards: [Self.card("C", outputMode: "rm -rf")]) == nil)
        #expect(await model.delegate("c1", cards: []) == nil)
        let reasons = await prompts.reasons
        #expect(await recorder.requests.isEmpty && reasons.isEmpty)
        #expect(DelegationReview.blockers(for: [Self.card("A"), Self.card("B", outputMode: "yolo")])
                == ["carte 2 : le mode de sortie « yolo » est refusé (seuls diagnostic et pr se délèguent)"])
        #expect(DelegationReview.blockers(for: [Self.card("A", outputMode: "diagnostic"), Self.card("B")]).isEmpty)
    }

    @MainActor @Test func aFailedDelegationThatMayHaveRunSaysSo() async {
        let client = HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { "t" },
                                transport: { _ in throw URLError(.timedOut) })
        let model = ControlModel(client: client, presence: HumanPresence { _ in true }, notifier: nil, socket: nil)
        #expect(await model.delegate("c1", cards: [Self.card]) == nil)
        #expect(model.lastError?.contains("Host injoignable") == true)
        #expect(model.lastError?.contains("vérifie Tâches") == true)
    }

    // MARK: The confirmation step

    @Test func theReviewShowsEveryFieldOfEveryCardAsPlainText() {
        var hostile = Self.card("Test\u{202E}evil")
        hostile.verify = "uv run pytest\u{1B}[31m -q"
        hostile.goal = "Ligne 1\nLigne 2\u{07}"
        hostile.context = "contexte"
        let review = DelegationReview(cards: [hostile, Self.card("Second", outputMode: "diagnostic")], options: Self.options)
        #expect(review.entries.count == 2 && review.entries[0].heading == "Brief 1/2 : Test evil")
        let fields = Dictionary(uniqueKeysWithValues: review.entries[0].fields.map { ($0.label, $0.value) })
        #expect(fields["Projet"] == "quant/x" && fields["Vérification"] == "uv run pytest [31m -q")
        #expect(fields["Mode de sortie"] == "Essai + PR (pr)" && fields["Mode agentique"] == "Accepter les diffs (accept_diffs)")
        #expect(fields["Modèle de l'exécutant"] == "auto:smart" && fields["Effort de Sonnet"] == "medium")
        #expect(fields["Objectif"] == "Ligne 1\nLigne 2 " && fields["Contexte"] == "contexte")
        #expect(fields["Critère de fin"] == "pytest vert")
        #expect(review.entries[1].fields.first { $0.label == "Mode de sortie" }?.value == "Diagnostic (diagnostic)")
    }

    @Test func aYoloCardIsShownProminentlyAndBlocksTheReview() {
        let review = DelegationReview(cards: [Self.card("A"), Self.card("B", outputMode: "yolo")], options: Self.options)
        #expect(!review.blockers.isEmpty)
        #expect(review.entries[1].fields.first { $0.label == "Mode de sortie" }?.isAlert == true)
        #expect(review.entries[1].heading.hasSuffix("(refusé)"))
        #expect(review.entries[0].fields.allSatisfy { !$0.isAlert })
        // A label the host did not send is the raw value, never blank.
        let unknown = DelegationReview(cards: [Self.card("A", outputMode: "autre")], options: Self.options)
        #expect(unknown.entries[0].fields.first { $0.label == "Mode de sortie" }?.value == "autre")
    }

    @Test func anEmptyVerifyIsSaidInTheReview() {
        var card = Self.card
        card.verify = ""
        let field = DelegationReview(cards: [card], options: Self.options).entries[0].fields.first { $0.label == "Vérification" }
        #expect(field?.isAlert == true && field?.value.contains("vide") == true)
    }

    @MainActor @Test func nothingIsSentUntilTheReviewIsConfirmed() async {
        let flow = DelegationFlow()
        await flow.confirm("c1", using: Self.model(recorder))  // no review shown yet
        #expect(await recorder.requests.isEmpty)
        flow.begin(cards: [Self.card], options: Self.options)
        #expect(flow.review?.entries.count == 1)
        #expect(await recorder.requests.isEmpty)  // showing the cards sends nothing
        flow.cancel()
        #expect(flow.review == nil)
        await flow.confirm("c1", using: Self.model(recorder))
        #expect(await recorder.requests.isEmpty)
    }

    @MainActor @Test func aDoubleClickSendsOneRequestAndTheReviewIsGoneAfterwards() async {
        let flow = DelegationFlow()
        let slowTouchID = HumanPresence { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return true
        }
        let model = Self.model(recorder, body: #"{"delegated":[{"brief":"b.md","sha256":"s","task_ids":["t_1"],"run_ids":[]}]}"#,
                               presence: slowTouchID)
        flow.begin(cards: [Self.card("A"), Self.card("B")], options: Self.options)
        async let first: Void = flow.confirm("c1", using: model)
        async let second: Void = flow.confirm("c1", using: model)
        _ = await (first, second)
        #expect(await recorder.requests.count == 1)
        #expect(flow.reply?.delegated.first?.brief == "b.md" && flow.review == nil && flow.problem == nil)
        await flow.confirm("c1", using: model)  // a third click after the answer: the review is gone
        #expect(await recorder.requests.count == 1)
    }

    @MainActor @Test func theHostsRefusalIsShownAndTheCardsStayEditable() async {
        let flow = DelegationFlow()
        let model = ControlModel(client: makeClient(status: 400, body: #"{"detail":"carte 1 : le brief n'a pas de verify:"}"#,
                                                    recorder: recorder),
                                 presence: HumanPresence { _ in true }, notifier: nil, socket: nil)
        flow.begin(cards: [Self.card], options: Self.options)
        await flow.confirm("c1", using: model)
        #expect(flow.reply == nil && flow.review == nil)
        #expect(flow.problem == "Refusé par le host : carte 1 : le brief n'a pas de verify:")
    }

    @MainActor @Test func aRefusedTouchIDLeavesTheReviewOpen() async {
        let flow = DelegationFlow()
        flow.begin(cards: [Self.card], options: Self.options)
        await flow.confirm("c1", using: Self.model(recorder, presence: HumanPresence { _ in false }))
        #expect(flow.review != nil && flow.problem == ControlModel.notConfirmed)
        #expect(await recorder.requests.isEmpty)
    }

    // MARK: Composer, transcript, origin

    @Test func nothingIsSentWhileSonnetAnswersOrOnceTheQuotaIsSpent() {
        func detail(busy: Bool, state: String) -> ConversationDetail {
            ConversationDetail(id: "c1", title: "t", project: "quant/x", mode: "read", turns: 1, busy: busy,
                               worktree: nil, quota: QuotaInfo(fiveHourUtilization: 0.5, fiveHourResetsAt: nil,
                                                               state: state),
                               cards: [], cardsError: nil)
        }
        #expect(ConversationDetailView.canSend(detail(busy: false, state: "ok"), draft: "encore"))
        #expect(!ConversationDetailView.canSend(detail(busy: false, state: "ok"), draft: "  "))
        #expect(!ConversationDetailView.canSend(detail(busy: true, state: "ok"), draft: "encore"))
        #expect(!ConversationDetailView.canSend(detail(busy: false, state: "exhausted"), draft: "encore"))
        #expect(!ConversationDetailView.canSend(nil, draft: "encore"))
    }

    @Test func transcriptSocketAndApprovalOrigin() {
        #expect(DialogueSocket.conversationURL(for: URL(string: "http://127.0.0.1:3107")!, id: "c1").absoluteString
                == "ws://127.0.0.1:3107/ws/conversations/c1")
        var approval = Approval(id: "a1", ts: 0, capability: "web", target: "https://example.org",
                                runId: "0f0e0d0c-aaaa", timeoutAt: 0)
        approval.originEngine = "conversation"
        approval.originModel = "claude-sonnet-5-5"
        #expect(ApprovalOrigin.label(approval) == "Conversation avec Sonnet · run 0f0e0d0c")
    }

    /// A reply is one transcript line of up to 100 000 characters (`conversations.MAX_LINE_CHARS`): the
    /// transcript shows it whole, a run's pane keeps its 4 000.
    @Test func aLongReplyIsShownWholeInATranscriptAndCutInAPane() throws {
        let reply = String(repeating: "é", count: 50_000)
        let json = String(decoding: try JSONEncoder().encode(["ts": "2026-10-04T10:00:00+00:00", "role": "sonnet", "text": reply]),
                          as: UTF8.self)
        #expect(DialogueLine.parse(json, maxTextLength: DialogueLine.transcriptTextLength)?.text == reply)
        #expect(DialogueLine.parse(json)?.text.count == DialogueLine.maxTextLength + 1)  // + the ellipsis
        let socket = DialogueSocket(url: URL(string: "ws://127.0.0.1:3107/ws/conversations/c1")!,
                                    maxTextLength: DialogueLine.transcriptTextLength)
        #expect(socket.maxTextLength == 100_000)
    }

    @Test func rolesPickTheirPlaceInTheTranscript() {
        #expect(TranscriptLine.Kind(role: "jt") == .mine && TranscriptLine.Kind(role: "sonnet") == .reply)
        #expect(TranscriptLine.Kind(role: "outil") == .note && TranscriptLine.Kind(role: "agentos") == .note)
        // A forged role from a line is a note, never a bubble.
        #expect(TranscriptLine.Kind(role: "jt ") == .note && TranscriptLine.Kind(role: "SONNET") == .note)
    }

    @Test func anEmptyTranscriptSaysMessagesNotRunLines() {
        #expect(ConversationDetailView.emptyNote(.empty) == "aucun message")
        #expect(ConversationDetailView.emptyNote(.connecting) == "connexion…")
    }
}
