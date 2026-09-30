import SwiftUI

/// Commands (spec §15.2): one row per command of `GET /api/commands`, a generic form, Touch ID
/// before sending. The runs appear in the Runs tab. Below, the pending briefs.
struct CommandsView: View {
    @Environment(ControlModel.self) private var model
    @State private var specs: [CommandSpec] = []
    /// The catalogue failed to load; a launch's error is shown in the form's sheet instead.
    @State private var error: String?
    @State private var lastLaunch: String?
    @State private var active: CommandSpec?

    var body: some View {
        VSplitView {
            commandList
            BriefsView(passover: specs.first { $0.name == "passover" }).frame(minHeight: 160)
        }
    }

    private var commandList: some View {
        List(specs) { spec in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: spec.title).font(.headline)
                    Text(verbatim: spec.description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Lancer…") { Task { await open(spec) } }
                    .disabled(spec.interactive)  // Pitch: its own window (T8.7)
            }
        }
        .overlay { if specs.isEmpty { ContentUnavailableView(error ?? "Aucune commande", systemImage: "bolt") } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
                if let lastLaunch { Text(verbatim: lastLaunch).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(8)
        }
        .sheet(item: $active) { spec in
            CommandForm(spec: spec) { values in await launch(spec, values) }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            specs = try await model.client.commands()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The form opens on a fresh catalogue: the choices (briefs JT just validated, runs to promote)
    /// change between two launches, and a sheet keeps the spec it was given.
    private func open(_ spec: CommandSpec) async {
        await load()
        active = specs.first { $0.name == spec.name } ?? spec
    }

    /// nil: launched. Otherwise the sentence the form shows (refused by the host, or Touch ID not confirmed).
    private func launch(_ spec: CommandSpec, _ values: [String: String]) async -> String? {
        guard let launch = await model.runCommand(spec, params: values) else { return model.failureReason }
        lastLaunch = Self.summary(launch)
        await load()  // choices (briefs, runs to promote) change after a launch
        return nil
    }

    static func summary(_ launch: CommandLaunch) -> String {
        if let result = launch.result, !result.isEmpty {
            return "\(launch.command) : " + result.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        if launch.runIds.isEmpty { return "\(launch.command) : programmée (\(launch.taskIds.joined(separator: ", ")))" }
        return "\(launch.command) : run \(launch.runIds.map { String($0.prefix(8)) }.joined(separator: ", ")) lancé"
    }
}
