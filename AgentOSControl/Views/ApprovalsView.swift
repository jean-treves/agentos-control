import SwiftUI

/// Pending approvals: tool, excerpt, rule, profile, task, time left; Approve (Touch ID) or Deny.
struct ApprovalsView: View {
    @Environment(ControlModel.self) private var model
    @State private var engine: String?  // nil: every engine

    /// The screen opens on this filter: a hosted test's only way in, the picker lives in the window's toolbar.
    init(engine: String? = nil) { _engine = State(initialValue: engine) }

    private var engines: [String] { ApprovalOrigin.engines(model.openApprovals.map(\.approval)) }

    /// A filter on an engine whose requests are all settled would hide the others: drop it then.
    private var shown: [ApprovalState] {
        guard let engine, engines.contains(engine) else { return model.openApprovals }
        return model.openApprovals.filter { ($0.approval.originEngine ?? "") == engine }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if shown.isEmpty {
                    ContentUnavailableView("Aucune approbation en attente", systemImage: "checkmark.shield")
                } else {
                    List(shown) { state in
                        ApprovalRow(state: state, context: model.contexts[state.id]).id(state.id)
                    }
                }
            }
            // `initial`: MainView switches to this screen after the click, so it appears with the request set.
            .onChange(of: model.revealedApprovalID, initial: true) { _, id in
                guard let id else { return }
                // A filter on another engine hides the card: drop it. The list is redrawn after this turn, so the
                // scroll waits for it.
                if !shown.contains(where: { $0.id == id }) { engine = nil }
                Task { proxy.scrollTo(id, anchor: .top) }
                model.clearReveal()
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
            let wording = ApprovalOrigin.wording(for: state.approval)
            HStack {
                if ApprovalOrigin.isOutOfMandate(state.approval) {
                    // Refusing lets the run go on, the likely answer: it is the default. Widening the mandate stops it.
                    Button(wording.deny) { Task { await model.deny(state.id) } }
                        .buttonStyle(.borderedProminent)
                    Button(wording.approve) { Task { await model.approve(state.id) } }
                        .buttonStyle(.bordered)
                } else {
                    Button(wording.approve) { Task { await model.approve(state.id) } }
                        .buttonStyle(.borderedProminent)
                    Button(wording.deny, role: .destructive) { Task { await model.deny(state.id) } }
                }
                switch state.phase {
                case .awaitingPresence: Text("Touch ID…").font(.caption)
                case .deciding: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
            .disabled(state.phase != .pending)
            if let note = wording.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
