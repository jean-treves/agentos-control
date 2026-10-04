import SwiftUI

/// One run: status, tool-call budget gauge, live receipts from the journal, output when done.
struct RunDetailView: View {
    let runID: String
    @Environment(ControlModel.self) private var model
    @State private var detail: RunDetail?
    @State private var journal: [JournalEvent] = []
    @State private var activity = RunActivity()
    @State private var limit = RunActivity.defaultMaxToolCalls
    @State private var error: String?
    @State private var showDialogue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail {
                Text(detail.prompt ?? "").font(.headline).lineLimit(3).textSelection(.enabled)
                Text(verbatim: detail.statusLine(activity: activity))
                    .font(.caption).foregroundStyle(.secondary)
                Gauge(value: Double(min(activity.toolCalls, limit)), in: 0...Double(max(limit, 1))) {
                    Text("Appels d'outils")
                } currentValueLabel: {
                    Text("\(activity.toolCalls) / \(limit)")
                }
            }
            DisclosureGroup("Dialogue en direct (Claude · Hermès)", isExpanded: $showDialogue) {
                // The two sockets exist only while this is open.
                if showDialogue { DialogueView(runID: runID).frame(minHeight: 280) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            List(journal.reversed()) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.date ?? .distantPast, format: .dateTime.hour().minute().second())
                        .monospacedDigit().foregroundStyle(.secondary)
                    Text(event.type).bold()
                    Text(event.summary).lineLimit(2).textSelection(.enabled)
                }
                .font(.caption)
            }
            if let output = detail?.output, detail?.status != "running" {
                DisclosureGroup("Sortie") {
                    ScrollView { Text(output).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 160)
                }
            }
            // host-v1 has no rollback route: v1 of the app points to the CLI instead.
            Text("Rollback : `agentos run rollback \(runID)` (pas de route host-v1)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Run \(runID.prefix(12))")
        .task(id: runID) { await follow() }
    }

    /// Polls every 2 s while the run is running, and for `RunDetail.lateReceipts` after it ended.
    private func follow() async {
        while !Task.isCancelled {
            do {
                let fresh = try await model.client.run(id: runID, after: 0)
                if detail == nil, fresh.asSummary.taskId != nil {
                    limit = RunActivity.toolCallLimit(for: fresh.asSummary, tasks: try await model.client.tasks())
                }
                detail = fresh
                let events = try await model.client.journal(afterSeq: activity.lastSeq, runID: runID)
                activity = activity.folding(events)
                // ponytail: keeps the last 500 receipts on screen; the full journal stays on the host.
                journal = Array((journal + events).suffix(500))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            if let detail, !detail.keepsListening(at: .now) { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
