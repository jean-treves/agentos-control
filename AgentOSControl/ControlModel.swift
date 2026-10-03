import Foundation
import Observation
import os

/// App state shared by the menu bar and the window. Polls the pending approvals every 2 s (the
/// socket never announces new ones) and the host status every 10 s; listens to `/ws/approvals` for
/// decisions made elsewhere and for the kill switch.
@Observable
final class ControlModel {
    let client: HostClient
    private(set) var book = ApprovalBook()
    private(set) var contexts: [String: ApprovalContext] = [:]
    /// nil until the first answer.
    private(set) var hostReachable: Bool?
    private(set) var killSwitchOn = false
    private(set) var breaker: BreakerStatus?
    private(set) var activeRuns: [RunSummary] = []
    /// nil until the notifier answers (or forever without one).
    private(set) var notificationsAuthorized: Bool?
    var lastError: String?

    @ObservationIgnored private let presence: HumanPresence
    @ObservationIgnored private let notifier: (any ApprovalNotifying)?
    @ObservationIgnored private let socket: ApprovalsSocket?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "model")

    init(client: HostClient, presence: HumanPresence, notifier: (any ApprovalNotifying)?, socket: ApprovalsSocket?) {
        self.client = client
        self.presence = presence
        self.notifier = notifier
        self.socket = socket
        notifier?.onAction = { [weak self] approvalID, approve in
            await self?.handleNotificationAction(approvalID: approvalID, approve: approve)
        }
    }

    static func live(settings: AppSettings) -> ControlModel {
        let token = ControlToken()
        let readToken: HostClient.TokenProvider
        if settings.readOnly { readToken = { nil } } else { readToken = { try await token.read() } }
        let client = HostClient(baseURL: settings.hostURL, token: readToken)
        let quiet = settings.readOnly || settings.isUnderTest
        return ControlModel(
            client: client, presence: .deviceOwner,
            notifier: quiet ? nil : ApprovalNotifier(),
            socket: settings.isUnderTest ? nil : ApprovalsSocket(baseURL: settings.hostURL))
    }

    var openApprovals: [ApprovalState] { book.open }

    var statusSymbol: String {
        Self.statusSymbol(
            reachable: hostReachable, killSwitch: killSwitchOn,
            breakerOpen: breaker.map { !$0.canLaunch } ?? false, pending: book.open.count)
    }

    /// Most serious condition first; SF Symbols because the menu bar renders the icon as a template.
    static func statusSymbol(reachable: Bool?, killSwitch: Bool, breakerOpen: Bool, pending: Int) -> String {
        switch reachable {
        case nil: return "circle.dashed"
        case false?: return "bolt.slash"
        case true?: break
        }
        if killSwitch { return "stop.circle.fill" }
        if breakerOpen { return "exclamationmark.triangle" }
        return pending > 0 ? "hand.raised.fill" : "checkmark.shield"
    }

    // MARK: Loops

    func start() {
        guard loops.isEmpty else { return }
        notifier?.install()
        // The system prompt can stay up for minutes: polling must not wait for JT's answer.
        if let notifier {
            loops.append(Task { await setNotificationsAuthorized(await notifier.requestAuthorization()) })
        }
        loops.append(Task {
            var tick = 0
            while !Task.isCancelled {
                await refreshApprovals()
                if tick % 5 == 0 { await refreshStatus() }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        })
        if let socket {
            loops.append(Task {
                for await message in socket.messages() { handle(message) }
            })
        }
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    func refreshApprovals() async {
        let pending: [Approval]
        do { pending = try await client.pendingApprovals() } catch {
            hostReachable = false
            return
        }
        hostReachable = true
        let before = openIDs
        book = book.reconciled(with: pending, now: .now)
        withdrawClosed(since: before)
        for state in book.open where !before.contains(state.id) {
            let context = await context(for: state.approval)
            contexts[state.id] = context
            if notificationsAuthorized == true { await notifier?.post(state.approval, context: context) }
        }
    }

    func refreshStatus() async {
        hostReachable = (try? await client.health()) == true
        do {
            killSwitchOn = try await client.killSwitch()
            breaker = try await client.breaker()
            activeRuns = try await client.runs(limit: 50).filter(\.isRunning)
        } catch {
            logger.error("status refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        if let notifier { await setNotificationsAuthorized(await notifier.isAuthorized()) }
    }

    /// Nothing is posted until notifications are allowed, so the moment they are (first answer, or
    /// JT allowing them later in System Settings) every open approval is posted.
    private func setNotificationsAuthorized(_ authorized: Bool) async {
        let granted = authorized && notificationsAuthorized != true
        notificationsAuthorized = authorized
        guard granted else { return }
        for state in book.open { await notifier?.post(state.approval, context: contexts[state.id]) }
    }

    func handle(_ message: SocketMessage) {
        switch message {
        case .killSwitch(let on):
            killSwitchOn = on
        case .approvalResolved(let id, let approved):
            transition(id, .resolvedRemotely(approved: approved))
        }
    }

    // MARK: Actions

    func approve(_ id: String) async {
        guard transition(id, .userApproved, from: .pending) != nil, let approval = book[id]?.approval else { return }
        let present = await presence.verify("approuver « \(approval.capability ?? "une action") » pour AgentOS")
        let event: ApprovalEvent = present ? .presenceConfirmed : .presenceFailed
        guard transition(id, event, from: .awaitingPresence) == .deciding(approve: true) else { return }
        await send(id, approve: true)
    }

    func deny(_ id: String) async {
        guard transition(id, .userDenied, from: .pending) != nil else { return }
        await send(id, approve: false)
    }

    /// A notification can outlive the process that posted it: refresh before trusting the id.
    func handleNotificationAction(approvalID: String, approve: Bool) async {
        if book[approvalID] == nil { await refreshApprovals() }
        guard book[approvalID] != nil else {
            logger.notice("approval \(approvalID, privacy: .public) is no longer pending")
            return
        }
        if approve { await self.approve(approvalID) } else { await deny(approvalID) }
    }

    func setKillSwitch(_ on: Bool) async {
        guard await presence.verify(on ? "activer l'arrêt d'urgence" : "désactiver l'arrêt d'urgence") else { return }
        do {
            killSwitchOn = try await client.setKillSwitch(on)
            lastError = nil
        } catch {
            report(error)
        }
    }

    func resetBreaker() async {
        guard await presence.verify("réarmer le disjoncteur") else { return }
        do {
            breaker = try await client.resetBreaker()
            lastError = nil
        } catch {
            report(error)
        }
    }

    /// `runCommand` and `validateBrief` return nothing without an error when JT refuses Touch ID:
    /// nothing left the app.
    static let notConfirmed = "Annulé : Touch ID non confirmé, rien n'a été envoyé."

    /// Why the last `runCommand` / `validateBrief` did nothing: the host's refusal, else Touch ID.
    var failureReason: String { lastError ?? Self.notConfirmed }

    /// Touch ID, then the command; nil when JT did not confirm or the host refused (see `lastError`).
    /// `timeout` nil keeps the session's 5 s; a command that moves files or waits for Haiku asks for more.
    func runCommand(_ spec: CommandSpec, params: [String: String], timeout: TimeInterval? = nil) async -> CommandLaunch? {
        lastError = nil  // a refused Touch ID must not show an older error
        // The prompt names the brief: from a row or from the form, JT sees which note leaves.
        let target = params["brief"].map { " sur « \($0) »" } ?? ""
        guard await presence.verify("lancer « \(spec.title) »\(target)") else { return nil }
        do {
            let launch = try await client.runCommand(spec.name, params: params, timeout: timeout)
            lastError = nil
            return launch
        } catch {
            report(error)
            return nil
        }
    }

    /// Touch ID, then the validation (spec §17.4); false when JT did not confirm or the host refused.
    func validateBrief(_ name: String, shown: String? = nil) async -> Bool {
        lastError = nil  // a refused Touch ID must not show an older error
        guard await presence.verify("valider le brief « \(name) »") else { return false }
        do {
            _ = try await client.validateBrief(name, shown: shown)
            lastError = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Touch ID, then the /optimize scan in the background; the sentence shown to JT.
    func startScan() async -> String {
        await launch("lancer l'analyse du stockage", label: "Analyse") { () async throws(HostError) in
            try await self.client.startScan()
        }
    }

    /// Touch ID, then a job-radar run in the background.
    func runJobRadar() async -> String {
        await launch("lancer job-radar", label: "job-radar") { () async throws(HostError) in
            try await self.client.runJobRadar()
        }
    }

    private func launch(
        _ reason: String, label: String, _ call: () async throws(HostError) -> LaunchReply
    ) async -> String {
        guard await presence.verify(reason) else { return "Annulé" }
        do {
            let reply = try await call()
            lastError = nil
            return Self.describe(reply, label: label)
        } catch {
            report(error)
            return error.localizedDescription
        }
    }

    static func describe(_ reply: LaunchReply, label: String) -> String {
        reply.started ? "\(label) lancée" : "\(label) non lancée : \(reply.reason ?? "raison inconnue")"
    }

    // MARK: Plumbing

    private var openIDs: Set<String> { Set(book.open.map(\.id)) }

    /// Applies `event` only from `phase`, nil otherwise. The machine turns an out-of-turn event into
    /// a no-op that keeps the phase, so the phase after it cannot tell "moved" from "ignored": a second
    /// Approve during Touch ID, or a Deny during the approve POST, would pass for the first one.
    private func transition(_ id: String, _ event: ApprovalEvent, from phase: ApprovalPhase) -> ApprovalPhase? {
        guard book[id]?.phase == phase else { return nil }
        return transition(id, event)
    }

    @discardableResult
    private func transition(_ id: String, _ event: ApprovalEvent) -> ApprovalPhase? {
        let before = openIDs
        book = book.applying(event, to: id)
        withdrawClosed(since: before)
        return book[id]?.phase
    }

    private func withdrawClosed(since before: Set<String>) {
        let closed = before.subtracting(openIDs)
        guard !closed.isEmpty else { return }
        notifier?.withdraw(Array(closed))
        contexts = contexts.filter { !closed.contains($0.key) }
    }

    private func send(_ id: String, approve: Bool) async {
        do {
            try await client.decide(approvalID: id, approve: approve)
            logger.notice("decision \(approve ? "approve" : "deny", privacy: .public) sent for \(id, privacy: .public)")
            transition(id, .decisionSucceeded)
            lastError = nil
        } catch {
            transition(id, .decisionFailed)
            report(error)
        }
    }

    /// 20 pages of the host's 500 events: enough for a long run, bounded for one that never journals
    /// its `approval.waiting`.
    private static let maxJournalPages = 20

    private func context(for approval: Approval) async -> ApprovalContext? {
        guard let runID = approval.runId else { return nil }
        do {
            let events = try await journal(of: runID, through: approval.id)
            return ApprovalContext(
                events: events, approvalID: approval.id, capability: approval.capability, tasks: try await client.tasks())
        } catch {
            logger.error("approval context unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The run's journal up to the page holding `approval.waiting` for `approvalID`, or its end.
    private func journal(of runID: String, through approvalID: String) async throws(HostError) -> [JournalEvent] {
        var events: [JournalEvent] = []
        for _ in 0..<Self.maxJournalPages {
            let page = try await client.journal(afterSeq: events.last?.seq ?? 0, runID: runID)
            events += page
            if page.isEmpty || page.contains(where: { $0.waits(for: approvalID) }) { break }
        }
        return events
    }

    private func report(_ error: HostError) {
        lastError = error.localizedDescription
        logger.error("\(error.localizedDescription, privacy: .public)")
    }
}
