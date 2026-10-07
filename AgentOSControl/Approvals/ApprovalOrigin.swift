import Foundation

/// Where an approval request comes from (spec §17.5, decision H7): engine, executor model, run,
/// agentic mode, and the arbiter's reason when it escalated to JT. Every string is shown as plain
/// text: the model and the reason come from the host, never from JT.
nonisolated enum ApprovalOrigin {
    static let modeLabels = ["manual": "Manuel", "accept_diffs": "Accepter les diffs", "auto": "Auto"]

    static func modeLabel(_ mode: String) -> String { modeLabels[mode] ?? mode }

    /// Out of mandate (decision D16) the host's `approve` stops the run and drafts a widened brief that waits for JT's
    /// validation in the briefs pane of Commandes, and `deny` lets the run continue without. Yes and no would mislead
    /// (JT clicked « Relancer avec ce mandat » meaning to refuse, E2E 32): the buttons say what happens.
    static func isOutOfMandate(_ approval: Approval) -> Bool { approval.actionClass == "out_of_mandate" }

    /// Refusing is the likely answer: its label is the same on the card and in the banner.
    static let refuseLabel = "Refuser : le run continue sans"
    /// The banner's button for `approve`: shorter than the card's label, but it still says the run stops.
    static let widenBannerLabel = "Élargir : arrêter le run (Touch ID)"

    /// One button of a card: its label, the host decision it sends (`approve` or `deny`) and how it is drawn.
    /// The label and the decision travel together, so the card cannot put « Élargir… » on a `deny` (E2E 32).
    nonisolated struct Choice: Equatable, Sendable, Identifiable {
        let title: String
        let approves: Bool
        let prominent: Bool
        let destructive: Bool
        var id: String { title }
    }

    /// A card's buttons in display order, the highlighted one first, and the line under them.
    nonisolated struct Wording: Equatable, Sendable {
        let choices: [Choice]
        let note: String?
    }

    static func wording(for approval: Approval) -> Wording {
        guard isOutOfMandate(approval) else {
            return Wording(
                choices: [
                    Choice(title: "Approuver (Touch ID)", approves: true, prominent: true, destructive: false),
                    Choice(title: "Refuser", approves: false, prominent: false, destructive: true),
                ], note: nil)
        }
        // Refusing lets the run go on: the likely answer, so the highlighted one. Widening the mandate stops the run.
        return Wording(
            choices: [
                Choice(title: refuseLabel, approves: false, prominent: true, destructive: false),
                Choice(
                    title: "Élargir le mandat : arrêter le run, nouveau brief (Touch ID)",
                    approves: true, prominent: false, destructive: false),
            ], note: "Le brief élargi attendra ta validation dans Commandes (volet des briefs).")
    }

    /// What Touch ID says for `approve`: out of mandate it stops the run, so it does not say « approuver ».
    static func approveReason(_ approval: Approval) -> String {
        let what = approval.capability ?? "une action"
        return isOutOfMandate(approval)
            ? "élargir le mandat de « \(what) » : le run s'arrête" : "approuver « \(what) » pour AgentOS"
    }

    static func label(_ approval: Approval) -> String {
        let engine: String? = switch approval.originEngine {
        case "hermes-cli": approval.originModel.map { "\($0) via Hermès" } ?? "Hermès"
        case "conversation": "Conversation avec Sonnet"
        case let other?: other
        case nil: nil
        }
        var parts = [engine, approval.runId.map { "run \($0.prefix(8))" }, approval.originMode.map(modeLabel)]
        if isOutOfMandate(approval) { parts.append("hors mandat") }
        if approval.escalatedBy == "arbiter" {
            parts.append("remontée par l'arbitre : \(approval.reason ?? "sans raison")")
        } else if let reason = approval.reason {
            parts.append(reason)
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Distinct engines of the open requests, for the filter ("" = origin unknown).
    static func engines(_ approvals: [Approval]) -> [String] {
        Array(Set(approvals.map { $0.originEngine ?? "" })).sorted()
    }
}
