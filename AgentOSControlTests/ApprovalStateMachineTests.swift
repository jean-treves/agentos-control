import Foundation
import Testing
@testable import AgentOSControl

private let deadline = Date(timeIntervalSince1970: 1_790_000_300)
private let approval = Approval(
    id: "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71", ts: 1_790_000_000, capability: "file_write",
    target: "README.md (append one line)", runId: "8d1e4b2a-5c6f-4a7b-9e0d-1f2a3b4c5d6e", timeoutAt: 1_790_000_300)

private func state(_ phase: ApprovalPhase) -> ApprovalState { ApprovalState(approval: approval, phase: phase) }

private func run(_ events: [ApprovalEvent], from phase: ApprovalPhase = .pending) -> ApprovalPhase {
    events.reduce(state(phase)) { $0.applying($1) }.phase
}

@Suite struct ApprovalStateMachineTests {
    @Test func approveGoesThroughPresenceThenDeciding() {
        #expect(run([.userApproved]) == .awaitingPresence)
        #expect(run([.userApproved, .presenceConfirmed]) == .deciding(approve: true))
        #expect(run([.userApproved, .presenceConfirmed, .decisionSucceeded]) == .approved)
    }

    @Test func failedOrCancelledPresenceReturnsToPendingAndSendsNothing() {
        #expect(run([.userApproved, .presenceFailed]) == .pending)
    }

    @Test func denySkipsPresence() {
        #expect(run([.userDenied]) == .deciding(approve: false))
        #expect(run([.userDenied, .decisionSucceeded]) == .denied)
    }

    @Test func failedDecisionCanBeRetried() {
        #expect(run([.userDenied, .decisionFailed]) == .pending)
        #expect(run([.userDenied, .decisionFailed, .userApproved]) == .awaitingPresence)
    }

    @Test func secondClickWhileBusyIsIgnored() {
        #expect(run([.userApproved, .userApproved]) == .awaitingPresence)
        #expect(run([.userApproved, .userDenied]) == .awaitingPresence)
        #expect(run([.userDenied, .userApproved]) == .deciding(approve: false))
    }

    @Test func vanishingBeforeTheDeadlineMeansResolvedElsewhere() {
        #expect(run([.vanished(at: deadline.addingTimeInterval(-1))]) == .resolvedElsewhere(approved: nil))
    }

    @Test func vanishingAtTheDeadlineIsExpired() {
        #expect(run([.vanished(at: deadline)]) == .expired)
        #expect(run([.userApproved, .vanished(at: deadline)]) == .expired)
    }

    @Test func expiryDuringTouchIDDropsTheLateConfirmation() {
        #expect(run([.userApproved, .vanished(at: deadline), .presenceConfirmed]) == .expired)
    }

    @Test func remoteResolutionDuringTouchIDDropsTheLateConfirmation() {
        #expect(run([.userApproved, .resolvedRemotely(approved: false), .presenceConfirmed])
            == .resolvedElsewhere(approved: false))
    }

    @Test func ownEchoFromTheSocketCompletesTheDecision() {
        #expect(run([.userApproved, .presenceConfirmed, .resolvedRemotely(approved: true)]) == .approved)
        #expect(run([.userDenied, .resolvedRemotely(approved: false), .decisionFailed]) == .denied)
    }

    @Test func conflictingSocketDecisionWins() {
        #expect(run([.userApproved, .presenceConfirmed, .resolvedRemotely(approved: false)])
            == .resolvedElsewhere(approved: false))
    }

    @Test func vanishingWhileDecidingWaitsForTheResponse() {
        #expect(run([.userDenied, .vanished(at: deadline)]) == .deciding(approve: false))
    }

    @Test(arguments: [
        ApprovalPhase.approved, .denied, .expired, .resolvedElsewhere(approved: nil), .resolvedElsewhere(approved: true),
    ])
    func terminalPhasesIgnoreEverything(terminal: ApprovalPhase) {
        let events: [ApprovalEvent] = [
            .userApproved, .presenceConfirmed, .presenceFailed, .userDenied, .decisionSucceeded,
            .decisionFailed, .resolvedRemotely(approved: true), .vanished(at: deadline),
        ]
        for event in events { #expect(run([event], from: terminal) == terminal) }
        #expect(!terminal.isOpen)
    }

    @Test func countdownNeverBuildsAnInvertedRange() {
        let late = deadline.addingTimeInterval(60)
        #expect(approval.countdown(from: late) == late...late)
        let early = deadline.addingTimeInterval(-60)
        #expect(approval.countdown(from: early) == early...deadline)
    }
}

@Suite struct ApprovalBookTests {
    private let other = Approval(
        id: "b7c8d9e0-1f2a-4b3c-8d4e-5f6a7b8c9d0e", ts: 1_790_000_010, capability: nil, target: nil,
        runId: nil, timeoutAt: 1_790_000_310)

    @Test func newApprovalsOpenAsPendingInArrivalOrder() {
        let book = ApprovalBook().reconciled(with: [other, approval], now: deadline)
        #expect(book.open.map(\.approval.id) == [approval.id, other.id])
        #expect(book.open.allSatisfy { $0.phase == .pending })
    }

    @Test func knownApprovalsKeepTheirPhase() {
        let book = ApprovalBook().reconciled(with: [approval], now: deadline)
            .applying(.userApproved, to: approval.id)
            .reconciled(with: [approval], now: deadline)
        #expect(book[approval.id]?.phase == .awaitingPresence)
    }

    @Test func decidedButStillListedIsNotReopened() {
        // A poll that started before our POST completed still lists the approval.
        let book = ApprovalBook().reconciled(with: [approval], now: deadline)
            .applying(.userDenied, to: approval.id)
            .applying(.decisionSucceeded, to: approval.id)
            .reconciled(with: [approval], now: deadline)
        #expect(book[approval.id]?.phase == .denied)
        #expect(book.open.isEmpty)
    }

    @Test func missingApprovalsCloseThenGetPruned() {
        let early = deadline.addingTimeInterval(-10)
        let closed = ApprovalBook().reconciled(with: [approval, other], now: early)
            .reconciled(with: [other], now: early)
        #expect(closed[approval.id]?.phase == .resolvedElsewhere(approved: nil))
        #expect(closed.open.map(\.approval.id) == [other.id])
        let pruned = closed.reconciled(with: [other], now: early)
        #expect(pruned[approval.id] == nil)
    }

    @Test func eventsForUnknownIDsAreIgnored() {
        let book = ApprovalBook().reconciled(with: [approval], now: deadline)
        #expect(book.applying(.userApproved, to: "unknown") == book)
    }
}

@Suite struct ApprovalContextTests {
    @Test func takesRuleAndProfileFromTheAskBeforeTheWaitingEventAndTheTaskTitle() throws {
        let events = try JSONDecoder.host.decode(JournalProbe.self, from: Data(Fixture.journal.utf8)).events
        let tasks = try JSONDecoder.host.decode(TasksProbe.self, from: Data(Fixture.tasks.utf8)).tasks
        let context = ApprovalContext(events: events, approvalID: approval.id, capability: "file_write", tasks: tasks)
        #expect(context == ApprovalContext(rule: "ask.file_write", profile: "ask", taskTitle: "Sample task"))
        #expect(context.summary == "tâche « Sample task » · profil ask · règle ask.file_write")
    }

    @Test func anAskWithoutThisApprovalsWaitingEventIsNotItsContext() throws {
        let events = try JSONDecoder.host.decode(JournalProbe.self, from: Data(Fixture.journal.utf8)).events
        let context = ApprovalContext(events: events, approvalID: "another-approval", capability: "file_write", tasks: [])
        #expect(context.rule == nil && context.profile == nil)
    }

    @Test func emptyJournalGivesAnEmptySummary() {
        let context = ApprovalContext(events: [], approvalID: approval.id, capability: "terminal", tasks: [])
        #expect(context.summary.isEmpty)
    }
}

private struct JournalProbe: Decodable { let events: [JournalEvent] }
private struct TasksProbe: Decodable { let tasks: [AgentTask] }

extension JSONDecoder {
    static var host: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Holds the first caller until `open()` and lets later ones straight through: a Touch ID sheet
/// left open, or a POST still in flight, while a second click comes in.
actor FirstCallGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?

    func pass() async {
        arrivals += 1
        guard arrivals == 1, !isOpen else { return }
        await withCheckedContinuation { held = $0 }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}

/// Polls `condition` for up to 2 s, so a test can wait until a background task is held at a gate.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

/// Counts Touch ID prompts and answers with a fixed result.
actor PresenceProbe {
    private(set) var prompts = 0
    func prompt() { prompts += 1 }
}

nonisolated private let emptyJournal = #"{"events":[]}"#
private let otherApprovalID = "c4d5e6f7-0a1b-4c2d-8e3f-4a5b6c7d8e9f"

/// One `/api/journal` page of the fixture approval's run; rows are (seq, type, data JSON).
nonisolated private func journalPage(_ rows: [(Int, String, String)]) -> String {
    let events = rows.map { seq, type, data in
        #"{"seq":\#(seq),"ts":"2026-09-23T21:06:12.017Z","run_id":"8d1e4b2a-5c6f-4a7b-9e0d-1f2a3b4c5d6e","#
            + #""task_id":"t_0a1b2c3d4e","type":"\#(type)","data":\#(data)}"#
    }
    return #"{"events":["# + events.joined(separator: ",") + "]}"
}

nonisolated private func ask(_ seq: Int, rule: String, profile: String) -> (Int, String, String) {
    (seq, "decision", #"{"capability":"file_write","verdict":"ask","rule":"\#(rule)","profile":"\#(profile)"}"#)
}

nonisolated private func waiting(_ seq: Int, for approvalID: String) -> (Int, String, String) {
    (seq, "approval.waiting", #"{"approval_id":"\#(approvalID)","capability":"file_write"}"#)
}

/// `journal` serves `/api/journal` by `after_seq`; nil serves `Fixture.journal` whatever the query.
private func routedClient(
    recorder: RequestRecorder, postGate: FirstCallGate? = nil,
    journal: (@Sendable (_ afterSeq: Int) -> String)? = nil
) -> HostClient {
    // Fixtures are main-actor state; the transport is @Sendable, so capture the strings.
    let (pending, journalFixture, tasks) = (Fixture.pending, Fixture.journal, Fixture.tasks)
    return HostClient(
        baseURL: URL(string: "http://127.0.0.1:3107")!,
        token: { "test-token" },
        transport: { request in
            await recorder.record(request)
            if request.httpMethod == "POST" { await postGate?.pass() }
            let body = switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/api/approvals/pending"): pending
            case ("GET", "/api/journal"):
                journal?(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "after_seq" }?.value.flatMap(Int.init) ?? 0) ?? journalFixture
            case ("GET", "/api/tasks"): tasks
            case ("POST", "/api/killswitch"): #"{"killswitch":true}"#
            default: #"{"status":"ok"}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
}

@Suite struct ApprovalFlowTests {
    let recorder = RequestRecorder()
    let probe = PresenceProbe()
    let id = "3f2b9c1e-7a44-4d0e-9b1a-0c5d2e8f6a71"

    private func model(
        present: Bool, touchID: FirstCallGate? = nil, postGate: FirstCallGate? = nil,
        journal: (@Sendable (_ afterSeq: Int) -> String)? = nil
    ) -> ControlModel {
        let probe = probe
        return ControlModel(
            client: routedClient(recorder: recorder, postGate: postGate, journal: journal),
            presence: HumanPresence { _ in
                await probe.prompt()
                await touchID?.pass()
                return present
            },
            notifier: nil, socket: nil)
    }

    private func posts() async -> [String] {
        await recorder.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.query() ?? "" }
    }

    @Test func refreshLoadsApprovalsWithTheirContext() async {
        let model = model(present: true)
        await model.refreshApprovals()
        #expect(model.openApprovals.map(\.approval.id) == [id, "b7c8d9e0-1f2a-4b3c-8d4e-5f6a7b8c9d0e"])
        #expect(model.contexts[id]?.rule == "ask.file_write")
        #expect(model.hostReachable == true)
    }

    @Test func contextComesFromTheAskJustBeforeThisApprovalsWaitingEvent() async {
        // Two approvals of one run pending at once: the later ask belongs to the other one.
        let page = journalPage([
            ask(1, rule: "rule.mine", profile: "ask"), waiting(2, for: id),
            ask(3, rule: "rule.other", profile: "trusted"), waiting(4, for: otherApprovalID),
        ])
        let model = model(present: true, journal: { $0 == 0 ? page : emptyJournal })
        await model.refreshApprovals()
        #expect(model.contexts[id]?.rule == "rule.mine")
        #expect(model.contexts[id]?.profile == "ask")
    }

    @Test func contextPagesALongRunUntilThisApprovalsWaitingEvent() async {
        // The first page (500 events on a real host) holds another approval's ask; ours is on the next.
        let first = journalPage([ask(1, rule: "rule.other", profile: "trusted"), waiting(2, for: otherApprovalID)])
        let second = journalPage([ask(3, rule: "rule.mine", profile: "ask"), waiting(4, for: id)])
        let model = model(present: true, journal: { [0: first, 2: second][$0] ?? emptyJournal })
        await model.refreshApprovals()
        #expect(model.contexts[id]?.rule == "rule.mine")
        let pages = await recorder.requests.filter { $0.url?.path() == "/api/journal" }.map { $0.url?.query() ?? "" }
        #expect(pages == [
            "after_seq=0&run_id=8d1e4b2a-5c6f-4a7b-9e0d-1f2a3b4c5d6e",
            "after_seq=2&run_id=8d1e4b2a-5c6f-4a7b-9e0d-1f2a3b4c5d6e",
        ])
    }

    @Test func contextPagingStopsAfterTwentyPages() async {
        // A run whose waiting event never shows up (Hermès gates journal none) must not page forever.
        let model = model(present: true, journal: { journalPage([($0 + 1, "health", "{}")]) })
        await model.refreshApprovals()
        #expect(await recorder.requests.filter { $0.url?.path() == "/api/journal" }.count == 20)
        #expect(model.contexts[id]?.rule == nil)
    }

    @Test func refusedTouchIDSendsNothing() async {
        let model = model(present: false)
        await model.refreshApprovals()
        await model.approve(id)
        #expect(await probe.prompts == 1)
        #expect(await posts().isEmpty)
        #expect(model.openApprovals.first?.phase == .pending)
    }

    @Test func confirmedTouchIDSendsExactlyOneApprove() async {
        let model = model(present: true)
        await model.refreshApprovals()
        await model.approve(id)
        #expect(await posts() == ["approval_id=\(id)&decision=approve"])
        #expect(model.openApprovals.map(\.approval.id) == ["b7c8d9e0-1f2a-4b3c-8d4e-5f6a7b8c9d0e"])
    }

    @Test func secondApproveWhileTouchIDIsOpenPromptsOnceAndPostsOnce() async {
        let touchID = FirstCallGate()
        let model = model(present: true, touchID: touchID)
        await model.refreshApprovals()
        let first = Task { await model.approve(id) }
        #expect(await eventually { await touchID.arrivals == 1 })
        // Same approval approved again from its notification while the first Touch ID sheet is up.
        await model.handleNotificationAction(approvalID: id, approve: true)
        await touchID.open()
        await first.value
        #expect(await probe.prompts == 1)
        #expect(await posts() == ["approval_id=\(id)&decision=approve"])
    }

    @Test func denyWhileTheApprovePOSTIsInFlightSendsNothing() async {
        let inFlight = FirstCallGate()
        let model = model(present: true, postGate: inFlight)
        await model.refreshApprovals()
        let approving = Task { await model.approve(id) }
        #expect(await eventually { await inFlight.arrivals == 1 })
        await model.deny(id)
        await inFlight.open()
        await approving.value
        #expect(await posts() == ["approval_id=\(id)&decision=approve"])
    }

    @Test func denyNeedsNoTouchID() async {
        let model = model(present: false)
        await model.refreshApprovals()
        await model.deny(id)
        #expect(await probe.prompts == 0)
        #expect(await posts() == ["approval_id=\(id)&decision=deny"])
    }

    @Test func notificationActionOnAnUnknownApprovalRefreshesFirst() async {
        let model = model(present: true)
        await model.handleNotificationAction(approvalID: id, approve: false)
        #expect(await posts() == ["approval_id=\(id)&decision=deny"])
    }

    @Test func notificationActionOnAGoneApprovalSendsNothing() async {
        let model = model(present: true)
        await model.handleNotificationAction(approvalID: "0f0f0f0f-0000-4000-8000-000000000000", approve: true)
        #expect(await probe.prompts == 0)
        #expect(await posts().isEmpty)
    }

    @Test func killSwitchNeedsTouchIDBothWays() async {
        let refused = model(present: false)
        await refused.setKillSwitch(true)
        #expect(await posts().isEmpty)
        let allowed = model(present: true)
        await allowed.setKillSwitch(true)
        #expect(await posts() == ["state=true"])
        #expect(allowed.killSwitchOn)
    }

    @Test func socketResolutionClosesTheApproval() async {
        let model = model(present: true)
        await model.refreshApprovals()
        model.handle(.approvalResolved(id: id, approved: false))
        #expect(model.openApprovals.count == 1)
        model.handle(.killSwitch(true))
        #expect(model.killSwitchOn)
    }

    @Test(arguments: [
        (Bool?.none, false, false, 0, "circle.dashed"),
        (false, true, true, 3, "bolt.slash"),
        (true, true, true, 3, "stop.circle.fill"),
        (true, false, true, 3, "exclamationmark.triangle"),
        (true, false, false, 3, "hand.raised.fill"),
        (true, false, false, 0, "checkmark.shield"),
    ])
    func statusSymbolPriority(reachable: Bool?, killSwitch: Bool, breakerOpen: Bool, pending: Int, symbol: String) {
        #expect(ControlModel.statusSymbol(
            reachable: reachable, killSwitch: killSwitch, breakerOpen: breakerOpen, pending: pending) == symbol)
    }

    @Test func settingsDetectTheTestHost() {
        #expect(AppSettings.current().isUnderTest)
        #expect(AppSettings.current().hostURL.absoluteString == "http://127.0.0.1:3107")
    }
}
