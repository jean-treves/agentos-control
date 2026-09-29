import AppKit
import SwiftUI

/// Mémoire (spec §16.3): one search over the vault index (SP4) and ai-memory's sessions and handoffs.
struct MemoryView: View {
    @Environment(ControlModel.self) private var model
    @State private var query = ""
    @State private var vault: [VaultHit] = []
    @State private var sessions: [MemoryHit] = []
    @State private var error: String?
    @State private var searched = false
    @State private var page: MemoryPage?

    private var isEmpty: Bool { vault.isEmpty && sessions.isEmpty }

    var body: some View {
        List {
            // One source down must not hide the other's hits, nor stay silent about it.
            if let error, !isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            Section("Vault et documents (\(vault.count))") {
                ForEach(vault) { hit in
                    Button { open(hit) } label: {
                        row(MemoryText.fileName(hit.path), MemoryText.plain(hit.snippet ?? ""), hit.source)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Sessions et passations (\(sessions.count))") {
                ForEach(sessions) { hit in
                    Button { Task { await show(hit) } } label: {
                        row(hit.title, MemoryText.plain(hit.snippet ?? ""), hit.project ?? "")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Chercher dans la mémoire")
        .onSubmit(of: .search) { Task { await search() } }
        .overlay {
            if isEmpty {
                ContentUnavailableView(
                    error ?? (searched ? "Aucun résultat" : "Tape une recherche, puis Entrée"), systemImage: "brain")
            }
        }
        .sheet(item: $page) { page in PageSheet(page: page) }
    }

    private func row(_ title: String, _ detail: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(detail).font(.caption).lineLimit(2)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        let results = await MemoryResults.search(text, client: model.client)
        vault = results.vault
        sessions = results.sessions
        error = results.error
        searched = true
    }

    private func open(_ hit: VaultHit) {
        let url = MemoryText.obsidianURL(hit.path, vault: AppSettings.vaultPath()) ?? URL(fileURLWithPath: hit.path)
        NSWorkspace.shared.open(url)
    }

    private func show(_ hit: MemoryHit) async {
        guard let workspace = hit.workspace, let project = hit.project else {
            error = "Page : espace ou projet manquant dans le résultat."
            return
        }
        do { page = try await model.client.memoryPage(path: hit.path, workspace: workspace, project: project) } catch {
            self.error = "Page : \(error.localizedDescription)"
        }
    }
}

private struct PageSheet: View {
    let page: MemoryPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(page.title).font(.title3.bold())
            ScrollView { Text(page.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button("Fermer") { dismiss() } }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// One search over both sources. One source failing (ai-memory down) never hides the other's hits.
struct MemoryResults: Equatable {
    var vault: [VaultHit] = []
    var sessions: [MemoryHit] = []
    var error: String?

    static func search(_ text: String, client: HostClient) async -> MemoryResults {
        async let vaultHits = client.vaultSearch(text)
        async let sessionHits = client.memoryQuery(text)
        var results = MemoryResults()
        var problems: [String] = []
        do { results.vault = try await vaultHits } catch { problems.append("Vault : \(error.localizedDescription)") }
        do { results.sessions = try await sessionHits } catch {
            problems.append("Sessions : \(error.localizedDescription)")
        }
        results.error = problems.isEmpty ? nil : problems.joined(separator: "\n")
        return results
    }
}

/// Pure helpers of the Memory screen (tested).
enum MemoryText {
    static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "")
    }

    static func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// Vault notes open in Obsidian; any other file opens in its default app.
    static func obsidianURL(_ path: String, vault: String) -> URL? {
        guard path.hasPrefix(vault + "/"), path.hasSuffix(".md") else { return nil }
        // URLQueryItem leaves `+` as is, which a query decoder reads back as a space (real note
        // "Cmd+maj+g sur finder.md"); `/` stays readable, as in Obsidian's own links.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "path", value: path.addingPercentEncoding(withAllowedCharacters: allowed))
        ]
        return components.url
    }
}
