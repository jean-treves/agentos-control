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
    /// false until the first successful load: a list being fetched is not an empty list.
    @State private var loaded = false
    /// The last poll failed; cleared by the next one that succeeds.
    @State private var loadError: String?
    /// Outcome of JT's last action (open, validate, launch).
    @State private var message: String?
    /// A validation or launch is in flight (Touch ID included): no second click.
    @State private var busy = false

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
                    Button("Valider") { run { await validate(brief.name) } }.disabled(busy)
                } else if let passover {
                    Button("Lancer") { run { await launch(passover, brief.name) } }.disabled(busy)
                }
            }
        }
        .overlay {
            if !loaded {
                if loadError == nil { ProgressView("Chargement des briefs…") }
            } else if briefs.isEmpty {
                ContentUnavailableView("Aucun brief en attente", systemImage: "doc.text")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let shown = loadError ?? message {
                Text(verbatim: shown).font(.caption).foregroundStyle(.secondary).padding(6)
            }
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
        do {
            briefs = try await model.client.briefs()
            loaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true  // set before the Task starts: a fast second click finds it already taken
        Task {
            await work()
            busy = false
        }
    }

    private func open(_ name: String) async {
        do { editing = try await model.client.brief(name) } catch { message = error.localizedDescription }
    }

    /// nil: saved, the editor closes. Otherwise the reason (409 launched, 400, token…) shown in the editor.
    private func save(_ name: String, _ text: String) async -> String? {
        do {
            try await model.client.saveBrief(name, text: text)
            message = "\(name) : brouillon enregistré, à valider de nouveau"
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func validate(_ name: String) async {
        message = await model.validateBrief(name)
            ? "\(name) : validé, sha256 au journal"
            : model.failureReason
        await load()
    }

    private func launch(_ spec: CommandSpec, _ name: String) async {
        let launch = await model.runCommand(spec, params: ["brief": name])
        message = launch.map(CommandsView.summary) ?? model.failureReason
        await load()
    }
}

/// The whole note, editable; saving always yields a draft (spec §17.4).
struct BriefEditor: View {
    let detail: BriefDetail
    /// nil: saved. A sentence: refused, shown here with the sheet kept open.
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: "\(detail.name) · \(detail.status) · \(detail.sha256.prefix(19))…")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced())
            if let error { Text(verbatim: error).font(.callout).foregroundStyle(.red) }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { text = detail.text }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer (brouillon)") {
                    saving = true
                    error = nil
                    Task {
                        error = await save(text)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(text == detail.text || saving)
            }
        }
    }
}
