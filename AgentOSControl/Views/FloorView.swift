import SwiftUI

/// One card per running agent: engine, last tool, remaining tool-call budget (after munder-difflin).
/// host-v1 has no `?status=running`, so running runs are filtered here.
struct FloorView: View {
    @Environment(ControlModel.self) private var model
    @State private var cards: [FloorCard] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 12) {
                ForEach(cards) { card in FloorCardView(card: card) }
            }
            .padding()
        }
        .overlay {
            if cards.isEmpty { ContentUnavailableView(error ?? "Aucun agent actif", systemImage: "person.3") }
        }
        .task { await pollEvery(.seconds(3)) { await load() } }
    }

    private func load() async {
        do {
            let running = try await model.client.runs(limit: 50).filter(\.isRunning)
            let tasks = running.contains { $0.taskId != nil } ? try await model.client.tasks() : []
            var next: [FloorCard] = []
            for run in running {
                let previous = cards.first { $0.id == run.id }?.activity ?? RunActivity()
                let events = try await model.client.journal(afterSeq: previous.lastSeq, runID: run.runId)
                next.append(FloorCard(
                    run: run, activity: previous.folding(events),
                    limit: RunActivity.toolCallLimit(for: run, tasks: tasks)))
            }
            cards = next
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FloorCard: Identifiable {
    let run: RunSummary
    let activity: RunActivity
    let limit: Int

    var id: String { run.id }
}

private struct FloorCardView: View {
    let card: FloorCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.title2)
                Text(card.activity.engine ?? "moteur ?").font(.headline)
                Spacer()
                Text(card.run.created, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(card.run.prompt ?? "").font(.caption).lineLimit(2)
            Text("Dernier outil : \(card.activity.lastTool ?? "aucun")").font(.caption)
            ProgressView(value: Double(min(card.activity.toolCalls, card.limit)), total: Double(max(card.limit, 1))) {
                Text("Reste \(card.activity.remainingToolCalls(limit: card.limit)) appel(s) d'outils sur \(card.limit)")
                    .font(.caption2)
            }
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}
