import AppKit
import SwiftUI

/// Pending briefs (spec §17.4): read, edit a draft, validate (Touch ID), launch a validated one.
/// Every field comes from the host (or from a note JT may have pasted): shown as plain text.
struct BriefsView: View {
    /// The catalogue's `passover` command: « Lancer » appears once T8.5 registers it.
    let passover: CommandSpec?
    @Environment(ControlModel.self) private var model
    @State private var briefs: [BriefSummary] = []
    @State private var editing: BriefDetail?
    @State private var message: String?

    var body: some View {
        List(briefs) { brief in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: brief.title).font(.headline)
                    Text(verbatim: [brief.project, Self.outputLabel(brief.outputMode),
                                    ApprovalOrigin.modeLabel(brief.agenticMode), brief.origin].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: brief.status).font(.caption).foregroundStyle(brief.isValidated ? .green : .orange)
                Button("Ouvrir…") { Task { await open(brief.name) } }
                Button("Obsidian") { NSWorkspace.shared.open(Self.obsidianURL(for: brief.name)) }
                if !brief.isValidated {
                    Button("Valider") { Task { await validate(brief.name) } }
                } else if let passover {
                    Button("Lancer") { Task { await launch(passover, brief.name) } }
                }
            }
        }
        .overlay { if briefs.isEmpty { ContentUnavailableView("Aucun brief en attente", systemImage: "doc.text") } }
        .safeAreaInset(edge: .bottom) {
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary).padding(6) }
        }
        .sheet(item: $editing) { detail in
            BriefEditor(detail: detail) { text in await save(detail.name, text) }
        }
        .task { await pollEvery(.seconds(10)) { await load() } }
    }

    static func obsidianURL(for name: String) -> URL {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: "JT-Vault"),
                                 URLQueryItem(name: "file", value: "05-Agent-OS/passover/\(name)")]
        return components.url ?? URL(string: "obsidian://")!
    }

    static func outputLabel(_ mode: String) -> String {
        ["diagnostic": "Diagnostic", "pr": "Essai + PR", "yolo": "YOLO"][mode] ?? mode
    }

    private func load() async {
        do { briefs = try await model.client.briefs() } catch { message = error.localizedDescription }
    }

    private func open(_ name: String) async {
        do { editing = try await model.client.brief(name) } catch { message = error.localizedDescription }
    }

    private func save(_ name: String, _ text: String) async -> Bool {
        do {
            try await model.client.saveBrief(name, text: text)
            message = "\(name) : brouillon enregistré, à valider de nouveau"
            await load()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func validate(_ name: String) async {
        message = await model.validateBrief(name)
            ? "\(name) : validé, sha256 au journal"
            : (model.lastError ?? CommandsView.notConfirmed)
        await load()
    }

    private func launch(_ spec: CommandSpec, _ name: String) async {
        let launch = await model.runCommand(spec, params: ["brief": name])
        message = launch.map(CommandsView.summary) ?? model.lastError ?? CommandsView.notConfirmed
        await load()
    }
}

/// The whole note, editable; saving always yields a draft (spec §17.4).
struct BriefEditor: View {
    let detail: BriefDetail
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: "\(detail.name) · \(detail.status) · \(detail.sha256.prefix(19))…")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced())
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { text = detail.text }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer (brouillon)") { Task { if await save(text) { dismiss() } } }
                    .disabled(text == detail.text)
            }
        }
    }
}
