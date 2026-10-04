import Foundation

/// Where an approval request comes from (spec §17.5, decision H7): engine, executor model, run,
/// agentic mode, and the arbiter's reason when it escalated to JT. Every string is shown as plain
/// text: the model and the reason come from the host, never from JT.
nonisolated enum ApprovalOrigin {
    static let modeLabels = ["manual": "Manuel", "accept_diffs": "Accepter les diffs", "auto": "Auto"]

    static func modeLabel(_ mode: String) -> String { modeLabels[mode] ?? mode }

    /// Out of mandate: « Approuver » means « Relancer avec ce mandat », never « do it ».
    static func isOutOfMandate(_ approval: Approval) -> Bool { approval.actionClass == "out_of_mandate" }

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
