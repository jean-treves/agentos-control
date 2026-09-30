import SwiftUI

/// Pending approvals: tool, excerpt, rule, profile, task, time left; Approve (Touch ID) or Deny.
struct ApprovalsView: View {
    @Environment(ControlModel.self) private var model
    @State private var engine: String?  // nil: every engine

    private var engines: [String] { ApprovalOrigin.engines(model.openApprovals.map(\.approval)) }

    /// A filter on an engine whose requests are all settled would hide the others: drop it then.
    private var shown: [ApprovalState] {
        guard let engine, engines.contains(engine) else { return model.openApprovals }
        return model.openApprovals.filter { ($0.approval.originEngine ?? "") == engine }
    }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView("Aucune approbation en attente", systemImage: "checkmark.shield")
            } else {
                List(shown) { state in
                    ApprovalRow(state: state, context: model.contexts[state.id])
                }
            }
        }
        .toolbar {
            Picker("Moteur", selection: $engine) {
                Text("Tous les moteurs").tag(String?.none)
                ForEach(engines, id: \.self) { name in
                    Text(verbatim: name.isEmpty ? "origine inconnue" : name).tag(String?.some(name))
                }
            }
        }
        .navigationTitle("Approbations")
    }
}

struct ApprovalRow: View {
    let state: ApprovalState
    let context: ApprovalContext?
    @Environment(ControlModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.approval.capability ?? "outil inconnu").font(.headline)
                Spacer()
                Text(timerInterval: state.approval.countdown(from: .now), countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let target = state.approval.target {
                Text(target).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
            }
            if let summary = context?.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            let origin = ApprovalOrigin.label(state.approval)
            if !origin.isEmpty {
                Text(verbatim: origin).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                let outOfMandate = ApprovalOrigin.isOutOfMandate(state.approval)
                // T8.6: only the label differs for now; « relancer avec ce mandat » gets its server semantics there.
                Button(outOfMandate ? "Relancer avec ce mandat (Touch ID)" : "Approuver (Touch ID)") {
                    Task { await model.approve(state.id) }
                }
                .buttonStyle(.borderedProminent)
                Button("Refuser", role: .destructive) { Task { await model.deny(state.id) } }
                switch state.phase {
                case .awaitingPresence: Text("Touch ID…").font(.caption)
                case .deciding: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
            .disabled(state.phase != .pending)
        }
        .padding(.vertical, 4)
    }
}
