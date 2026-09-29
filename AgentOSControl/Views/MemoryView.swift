import AppKit
import SwiftUI

/// Mémoire (spec §16.3): one search over the vault index (SP4) and ai-memory's sessions and handoffs.
struct MemoryView: View {
    @Environment(ControlModel.self) private var model
    @State private var memory = MemoryModel()
    @State private var query = ""

    var body: some View {
        List {
            // One source down must not hide the other's hits, nor stay silent about it.
            if let message = memory.message, !memory.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Section("Vault et documents (\(memory.vault.count))") {
                ForEach(memory.vault) { hit in
                    Button { open(hit) } label: {
                        row(MemoryText.fileName(hit.path), MemoryText.plain(hit.snippet ?? ""), hit.source)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Sessions et passations (\(memory.sessions.count))") {
                ForEach(memory.sessions) { hit in
                    Button { memory.show(hit, client: model.client) } label: {
                        row(hit.title, MemoryText.plain(hit.snippet ?? ""), hit.project ?? "")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Chercher dans la mémoire")
        .onSubmit(of: .search) { memory.search(query, client: model.client) }
        .overlay {
            if memory.isEmpty {
                ContentUnavailableView(
                    memory.message ?? (memory.searched ? "Aucun résultat" : "Tape une recherche, puis Entrée"),
                    systemImage: "brain")
            }
        }
        .sheet(item: $memory.page) { page in PageSheet(page: page) }
    }

    private func row(_ title: String, _ detail: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(detail).font(.caption).lineLimit(2)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A vault note opens in Obsidian; anything else is only revealed in Finder, never opened: a host-supplied
    /// path could be an app or a script (the app executes nothing, spec §16.5).
    private func open(_ hit: VaultHit) {
        switch MemoryText.openAction(hit.path, vault: AppSettings.vaultPath()) {
        case .obsidian(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// State of the Memory screen. A new search or click cancels the previous one, and a cancelled one never
/// writes: the latest request wins whatever order the answers arrive in.
@Observable final class MemoryModel {
    private(set) var vault: [VaultHit] = []
    private(set) var sessions: [MemoryHit] = []
    private(set) var searched = false
    var page: MemoryPage?
    private var searchError: String?
    private var pageError: String?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pageTask: Task<Void, Never>?

    var isEmpty: Bool { vault.isEmpty && sessions.isEmpty }

    /// The search failures and the page failure, one per line.
    var message: String? {
        let lines = [searchError, pageError].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func search(_ query: String, client: HostClient) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        searchTask?.cancel()
        searchTask = Task {
            let results = await MemoryResults.search(text, client: client)
            guard !Task.isCancelled else { return }  // a cancelled request's error is not a failure
            vault = results.vault
            sessions = results.sessions
            searchError = results.error
            pageError = nil
            searched = true
        }
    }

    func show(_ hit: MemoryHit, client: HostClient) {
        guard let workspace = hit.workspace, let project = hit.project else {
            pageError = "Page : espace ou projet manquant dans le résultat."
            return
        }
        pageTask?.cancel()
        pageTask = Task {
            do {
                let loaded = try await client.memoryPage(path: hit.path, workspace: workspace, project: project)
                guard !Task.isCancelled else { return }
                page = loaded
                pageError = nil
            } catch {
                guard !Task.isCancelled else { return }
                pageError = "Page : \(error.localizedDescription)"
            }
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

    /// What a click on a vault-index hit does.
    enum OpenAction: Equatable {
        case obsidian(URL)
        case reveal(URL)
    }

    static func openAction(_ path: String, vault: String) -> OpenAction {
        if let url = obsidianURL(path, vault: vault) { return .obsidian(url) }
        return .reveal(URL(fileURLWithPath: path))
    }

    /// Absolute `path` without `.`, `..` and empty components. Not `standardizedFileURL`: it rewrites
    /// accents to their decomposed form, and Obsidian looks notes up by their exact name.
    private static func resolved(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `obsidian://` link of a `.md` note that really lies under `vault`; nil for anything else. `..` is
    /// resolved before the test, so a path cannot climb out of the vault; a vault that is not an absolute
    /// path (empty, relative, `/`) matches nothing.
    static func obsidianURL(_ path: String, vault: String) -> URL? {
        guard vault.hasPrefix("/"), path.hasPrefix("/") else { return nil }
        let root = resolved(vault)
        let note = resolved(path)
        guard root != "/", note.hasPrefix(root + "/"), note.hasSuffix(".md") else { return nil }
        // URLQueryItem leaves `+` as is, which a query decoder reads back as a space (real note
        // "Cmd+maj+g sur finder.md"); `/` stays readable, as in Obsidian's own links.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))
        guard let value = note.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.percentEncodedQueryItems = [URLQueryItem(name: "path", value: value)]
        return components.url
    }
}
