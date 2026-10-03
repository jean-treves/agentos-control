import SwiftUI

struct RunsView: View {
    @Environment(ControlModel.self) private var model
    @State private var runs: [RunSummary] = []
    @State private var error: String?
    @State private var cleaning = false

    var body: some View {
        NavigationStack {
            List(runs) { run in
                NavigationLink(value: run.runId) { RunRow(run: run) }
            }
            .navigationDestination(for: String.self) { RunDetailView(runID: $0) }
            .toolbar { Button("Ménage…") { cleaning = true } }
            .sheet(isPresented: $cleaning) { CleanupSheet() }
            .overlay {
                if runs.isEmpty {
                    ContentUnavailableView(error ?? "Aucun run", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .task {
            await pollEvery(.seconds(5)) {
                do {
                    runs = try await model.client.runs(limit: 50)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct RunRow: View {
    let run: RunSummary

    var body: some View {
        HStack {
            Image(systemName: run.isRunning ? "play.circle.fill" : run.status == "completed" ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(run.isRunning ? .green : run.status == "completed" ? .secondary : .red)
            VStack(alignment: .leading) {
                Text(run.prompt ?? "").lineLimit(1)
                Text("\(run.status) · \(run.source ?? "?")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(run.created, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
    }
}
