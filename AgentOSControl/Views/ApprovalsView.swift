import SwiftUI

/// Pending approvals: tool, excerpt, rule, profile, task, time left; Approve (Touch ID) or Deny.
struct ApprovalsView: View {
    @Environment(ControlModel.self) private var model

    var body: some View {
        Group {
            if model.openApprovals.isEmpty {
                ContentUnavailableView("Aucune approbation en attente", systemImage: "checkmark.shield")
            } else {
                List(model.openApprovals) { state in
                    ApprovalRow(state: state, context: model.contexts[state.id])
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
            HStack {
                Button("Approuver (Touch ID)") { Task { await model.approve(state.id) } }
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
