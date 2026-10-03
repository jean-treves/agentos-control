import SwiftUI

/// The reply of the `menage` command (`kernel/minibots.propose`): what Haiku left on the list.
nonisolated struct CleanupProposal: Equatable, Sendable {
    let id: String
    let count: Int
    /// As the host writes it (`412.5`).
    let totalMB: String
    let items: [String]

    var isEmpty: Bool { count == 0 }

    /// nil when the reply holds no proposal. Every value comes from the host: shown as plain text.
    init?(result: [String: String]?) {
        guard let result, let id = result["proposal"] else { return nil }
        self.id = id.plainText()
        count = Int(result["count"] ?? "") ?? 0
        totalMB = (result["total_mb"] ?? "0").plainText()
        // With nothing to tidy the host answers « rien à ranger » in the same field.
        items = count == 0 ? [] : (result["items"] ?? "").split(separator: "\n").map { String($0).plainText() }
    }

    /// The reply of `menage-appliquer` (`kernel/minibots.apply`) as one sentence.
    static func outcome(_ result: [String: String]) -> String {
        let applied = (result["applied"] ?? "0").plainText()
        var text = "\(applied) appliqué(s), \((result["skipped"] ?? "0").plainText()) ignoré(s)."
        if applied != "0", let trash = result["trash"], !trash.isEmpty { text += " Rangé dans \(trash.plainText())." }
        if let reasons = result["reasons"], !reasons.isEmpty { text += " Ignoré : \(reasons.plainText())" }
        return text
    }
}

/// Cleanup proposed like a PR (spec §17.6): Haiku's list first, JT applies it with Touch ID.
struct CleanupSheet: View {
    @Environment(ControlModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var proposal: CleanupProposal?
    @State private var message: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let proposal {
                Text(verbatim: "\(proposal.count) élément(s), \(proposal.totalMB) Mo").font(.headline)
                ScrollView {
                    Text(verbatim: proposal.isEmpty ? "Rien à ranger." : proposal.items.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Le diff de chaque worktree est archivé en patch avant son retrait ; les fichiers ignorés et les dossiers tmp vont dans _a-trier. Aucune branche supprimée.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if message == nil {
                ProgressView("Haiku prépare la liste…")
            }
            if let message { Text(verbatim: message).font(.caption).textSelection(.enabled) }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
        .task { await propose() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Appliquer (Touch ID)") { Task { await apply() } }
                    .disabled(proposal == nil || proposal?.isEmpty == true || applying)
            }
        }
    }

    /// No Touch ID to look: the proposal touches nothing (the control token is still sent). It waits for
    /// Haiku, hence the long timeout.
    private func propose() async {
        do {
            let launch = try await model.client.runCommand("menage", params: [:], timeout: HostClient.slowCommandTimeout)
            proposal = CleanupProposal(result: launch.result)
            if proposal == nil { message = "Réponse du host sans proposition." }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Touch ID, then the frozen proposal. A second Apply on the same proposal reaches the host, which refuses it.
    private func apply() async {
        guard let id = proposal?.id, !applying else { return }
        applying = true
        defer { applying = false }
        message = nil
        do {
            guard let spec = try await model.client.commands().first(where: { $0.name == "menage-appliquer" }) else {
                message = "commande « menage-appliquer » absente du host"
                return
            }
            if let launch = await model.runCommand(spec, params: ["proposal": id]) {
                message = CleanupProposal.outcome(launch.result ?? [:])
            } else {
                message = model.failureReason
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
