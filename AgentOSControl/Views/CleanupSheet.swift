import SwiftUI

/// The reply of the `menage` command (`kernel/minibots.propose`): what Haiku left on the list.
nonisolated struct CleanupProposal: Equatable, Sendable {
    let id: String
    let count: Int
    /// As the host writes it (`412.5`).
    let totalMB: String
    let items: [String]
    /// Folders left on purpose, as the host words it; nil from a host that does not say.
    let kept: String?

    var isEmpty: Bool { count == 0 }

    /// nil when the reply holds no proposal. Every value comes from the host: shown as plain text.
    init?(result: [String: String]?) {
        guard let result, let id = result["proposal"] else { return nil }
        self.id = id.plainText()
        count = Int(result["count"] ?? "") ?? 0
        totalMB = (result["total_mb"] ?? "0").plainText()
        // With nothing to tidy the host answers « rien à ranger » in the same field.
        items = count == 0 ? [] : (result["items"] ?? "").split(separator: "\n").map { String($0).plainText() }
        kept = result["kept"].map { $0.plainText() }
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

/// What the Ménage sheet does, apart from the view so that a test drives the path the sheet takes.
@Observable
final class CleanupFlow {
    private(set) var proposal: CleanupProposal?
    /// The host's account of an apply that went through: where the files went, what was left.
    private(set) var report: String?
    /// Why the last step did nothing (the host's refusal, Touch ID not confirmed, host unreachable).
    private(set) var problem: String?
    private(set) var applying = false

    var canApply: Bool { proposal.map { !$0.isEmpty } == true && !applying }

    /// No Touch ID to look: the proposal touches nothing (the control token is still sent). It waits for
    /// Haiku, hence the long timeout.
    func propose(using model: ControlModel) async {
        do {
            let launch = try await model.client.runCommand("menage", params: [:], timeout: HostClient.slowCommandTimeout)
            proposal = CleanupProposal(result: launch.result)
            if proposal == nil { problem = "Réponse du host sans proposition." }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Touch ID, then the frozen proposal. The host moves files and runs git for each worktree: the long timeout,
    /// else the sheet says « Host injoignable » over a ménage that happened. A refused second apply (the host
    /// applies a proposal once) leaves the first report where it is: it names the folder the files went to.
    func apply(using model: ControlModel) async {
        guard let id = proposal?.id, !applying else { return }
        applying = true
        defer { applying = false }
        problem = nil
        do {
            guard let spec = try await model.client.commands().first(where: { $0.name == "menage-appliquer" }) else {
                problem = "commande « menage-appliquer » absente du host"
                return
            }
            if let launch = await model.runCommand(spec, params: ["proposal": id], timeout: HostClient.slowCommandTimeout) {
                report = CleanupProposal.outcome(launch.result ?? [:])
            } else {
                problem = model.failureReason
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Cleanup proposed like a PR (spec §17.6): Haiku's list first, JT applies it with Touch ID.
struct CleanupSheet: View {
    @Environment(ControlModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow = CleanupFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let proposal = flow.proposal {
                Text(verbatim: "\(proposal.count) élément(s), \(proposal.totalMB) Mo").font(.headline)
                if let kept = proposal.kept { Text(verbatim: kept).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    Text(verbatim: proposal.isEmpty ? "Rien à ranger." : proposal.items.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Le diff de chaque worktree est archivé en patch avant son retrait ; les environnements virtuels et les caches partent avec lui, les autres fichiers ignorés et les dossiers tmp vont dans _a-trier. Aucune branche supprimée.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if flow.problem == nil {
                ProgressView("Haiku prépare la liste…")
            }
            if let report = flow.report { Text(verbatim: report).font(.caption).textSelection(.enabled) }
            if let problem = flow.problem { Text(verbatim: problem).font(.caption).textSelection(.enabled) }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
        .task { await flow.propose(using: model) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Appliquer (Touch ID)") { Task { await flow.apply(using: model) } }
                    .disabled(!flow.canApply)
            }
        }
    }
}
