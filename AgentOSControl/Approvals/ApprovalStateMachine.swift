import Foundation

/// Where one approval stands on this Mac. Only `.deciding` sends a decision, and `.approve == true`
/// is reachable only through `.awaitingPresence` (Touch ID).
nonisolated enum ApprovalPhase: Equatable, Sendable {
    case pending
    case awaitingPresence
    case deciding(approve: Bool)
    case approved
    case denied
    case expired
    /// Decided by someone else (cockpit, Telegram); nil when only its disappearance was seen.
    case resolvedElsewhere(approved: Bool?)

    var isOpen: Bool {
        switch self {
        case .pending, .awaitingPresence, .deciding: true
        case .approved, .denied, .expired, .resolvedElsewhere: false
        }
    }
}

nonisolated enum ApprovalEvent: Equatable, Sendable {
    case userApproved
    case presenceConfirmed
    case presenceFailed
    case userDenied
    case decisionSucceeded
    case decisionFailed
    /// `approval_resolved` from `/ws/approvals`, including the echo of our own decision.
    case resolvedRemotely(approved: Bool)
    /// No longer in `GET /api/approvals/pending`.
    case vanished(at: Date)
}

nonisolated struct ApprovalState: Equatable, Sendable, Identifiable {
    let approval: Approval
    let phase: ApprovalPhase

    var id: String { approval.id }

    func applying(_ event: ApprovalEvent) -> ApprovalState {
        ApprovalState(approval: approval, phase: next(on: event))
    }

    private func next(on event: ApprovalEvent) -> ApprovalPhase {
        switch (phase, event) {
        case (.pending, .userApproved): .awaitingPresence
        case (.pending, .userDenied): .deciding(approve: false)
        case (.awaitingPresence, .presenceConfirmed): .deciding(approve: true)
        case (.awaitingPresence, .presenceFailed): .pending
        case (.deciding(let approve), .decisionSucceeded): approve ? .approved : .denied
        case (.deciding, .decisionFailed): .pending
        // The server broadcasts before it answers our POST: a matching decision is our own echo.
        case (.deciding(let mine), .resolvedRemotely(let approved)):
            mine == approved ? (approved ? .approved : .denied) : .resolvedElsewhere(approved: approved)
        case (.pending, .resolvedRemotely(let approved)), (.awaitingPresence, .resolvedRemotely(let approved)):
            .resolvedElsewhere(approved: approved)
        case (.pending, .vanished(let time)), (.awaitingPresence, .vanished(let time)):
            time >= approval.deadline ? .expired : .resolvedElsewhere(approved: nil)
        // Everything else (double clicks, late Touch ID answers, events on closed approvals) is a no-op.
        default: phase
        }
    }
}

/// Every approval this Mac knows about, reconciled with each poll of the pending list.
nonisolated struct ApprovalBook: Equatable, Sendable {
    private var states: [String: ApprovalState] = [:]

    subscript(id: String) -> ApprovalState? { states[id] }

    /// Open approvals, oldest first.
    var open: [ApprovalState] {
        states.values.filter(\.phase.isOpen).sorted { ($0.approval.ts, $0.id) < ($1.approval.ts, $1.id) }
    }

    func applying(_ event: ApprovalEvent, to id: String) -> ApprovalBook {
        guard let current = states[id] else { return self }
        var copy = self
        copy.states[id] = current.applying(event)
        return copy
    }

    /// New ids open as `.pending`; listed ids keep their phase (a closed one stays closed, so a
    /// poll racing our own POST cannot reopen it); missing open ids get `.vanished`; missing
    /// closed ids are dropped.
    func reconciled(with pending: [Approval], now: Date) -> ApprovalBook {
        let listed = Set(pending.map(\.id))
        var copy = ApprovalBook()
        for (id, current) in states {
            if listed.contains(id) {
                copy.states[id] = current
            } else if current.phase.isOpen {
                copy.states[id] = current.applying(.vanished(at: now))
            }
        }
        for approval in pending where copy.states[approval.id] == nil {
            copy.states[approval.id] = ApprovalState(approval: approval, phase: .pending)
        }
        return copy
    }
}

/// Rule, profile and task behind an approval. `GET /api/approvals/pending` carries none of them,
/// the run's journal does (last `decision` with `verdict: ask`).
nonisolated struct ApprovalContext: Equatable, Sendable {
    let rule: String?
    let profile: String?
    let taskTitle: String?

    var summary: String {
        [taskTitle.map { "tâche « \($0) »" }, profile.map { "profil \($0)" }, rule.map { "règle \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

extension ApprovalContext {
    /// ponytail: reads the first 500 journal events of the run (the host's default page); a run
    /// that asks after that shows no context. Page with `after_seq` if that ever happens.
    nonisolated init(events: [JournalEvent], capability: String?, tasks: [AgentTask]) {
        let ask = events.last {
            $0.type == "decision" && $0.data?.verdict == "ask"
                && (capability == nil || $0.data?.capability == capability)
        }
        let taskId = ask?.taskId ?? events.first { $0.taskId != nil }?.taskId
        self.init(
            rule: ask?.data?.rule,
            profile: ask?.data?.profile,
            taskTitle: tasks.first { $0.taskId == taskId }?.title)
    }
}

extension Approval {
    /// Range for a countdown `Text`; an approval past its deadline gives an empty range instead of
    /// the inverted one that traps at runtime.
    nonisolated func countdown(from now: Date) -> ClosedRange<Date> {
        now...max(now, deadline)
    }
}
