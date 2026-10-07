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
    /// The Drawback just launched: its time, for « Armer le réveil » (one `pmset` wake, JT's password).
    @State private var armDate: Date?
    @State private var armMessage: String?

    var body: some View {
        VSplitView {
            commandList
            BriefsView(passover: specs.first { $0.name == "passover" }).frame(minHeight: 160)
        }
    }

    private var commandList: some View {
        List(Self.listed(specs)) { spec in
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
        .overlay { if Self.listed(specs).isEmpty { ContentUnavailableView(error ?? "Aucune commande", systemImage: "bolt") } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
                if let lastLaunch { Text(verbatim: lastLaunch).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let armDate {
                    Button("Armer le réveil (\(armDate.formatted(date: .abbreviated, time: .shortened)))…") {
                        let armed = NightArm.arm(at: armDate.addingTimeInterval(30))
                        armMessage = armed.error ?? ["Réveil armé", armed.notice].compactMap { $0 }.joined(separator: " — ")
                    }
                }
                if let armMessage { Text(verbatim: armMessage).font(.caption) }
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
        armDate = Self.armTime(spec.name, values)
        armMessage = nil
        await load()  // choices (briefs, runs to promote) change after a launch
        return nil
    }

    /// Runs ▸ Ménage… shows the list before « Appliquer »; the generic form would apply whatever proposal
    /// comes first in the host's choices, one JT never saw (D24: the proposal is applied as it was shown).
    private static let cleanupOnly: Set<String> = ["menage", "menage-appliquer"]

    /// Only a Drawback wakes the Mac, at the time the form sent (and the host accepted).
    static func armTime(_ command: String, _ values: [String: String]) -> Date? {
        guard command == "drawback" else { return nil }
        return values["at"].flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    static func listed(_ specs: [CommandSpec]) -> [CommandSpec] { specs.filter { !cleanupOnly.contains($0.name) } }

    static func summary(_ launch: CommandLaunch) -> String {
        if let result = launch.result, !result.isEmpty {
            return "\(launch.command) : " + result.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        if launch.runIds.isEmpty { return "\(launch.command) : programmée (\(launch.taskIds.joined(separator: ", ")))" }
        return "\(launch.command) : run \(launch.runIds.map { String($0.prefix(8)) }.joined(separator: ", ")) lancé"
    }
}
