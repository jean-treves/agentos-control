import Foundation
import Testing
@testable import AgentOSControl

@Suite struct MemoryTests {
    @Test func snippetsLoseTheirMarkTags() {
        #expect(MemoryText.plain("…je développe le <mark>Trinavers</mark>, un…") == "…je développe le Trinavers, un…")
        #expect(MemoryText.fileName("/Users/me/Vault/08-Tech-Notes/hermes chat.md") == "hermes chat")
    }

    @Test func vaultNotesOpenInObsidianOtherFilesDoNot() {
        let vault = "/Users/me/Vault"
        let url = MemoryText.obsidianURL("\(vault)/08-Tech-Notes/x y.md", vault: vault)
        #expect(url?.absoluteString == "obsidian://open?path=/Users/me/Vault/08-Tech-Notes/x%20y.md")
        #expect(MemoryText.obsidianURL("/Users/me/code/AgentOS/documents/a.md", vault: vault) == nil)
        #expect(MemoryText.obsidianURL("\(vault)-other/a.md", vault: vault) == nil)
    }

    /// Real vault names contain `+` (Cmd+maj+g sur finder.md); `+` must not be read back as a space.
    @Test func obsidianURLEscapesWhatWouldSplitTheQuery() {
        let vault = "/Users/me/Vault"
        let url = MemoryText.obsidianURL("\(vault)/08-Tech-Notes/Imported/Cmd+maj+g & é #1 100%.md", vault: vault)
        #expect(url?.absoluteString == "obsidian://open?path=/Users/me/Vault/08-Tech-Notes/Imported/Cmd%2Bmaj%2Bg%20%26%20%C3%A9%20%231%20100%25.md")
    }

    @Test func sessionHitsAreIdentifiedByWorkspaceProjectAndPath() throws {
        let json = #"{"path":"sessions/a.md","title":"T","snippet":null,"project":"p","workspace":"w","rank":null}"#
        let hit = try JSONDecoder().decode(MemoryHit.self, from: Data(json.utf8))
        #expect(hit.id == "w/p/sessions/a.md" && hit.snippet == nil && hit.rank == nil)
    }

    /// A note that is not under the vault is only ever revealed, never opened: `.app`, `.command`,
    /// `.dmg` and the like would launch. (`obsidianURL` is already nil for those.)
    @Test func onlyVaultNotesOpenEverythingElseIsRevealed() {
        let vault = "/Users/me/Vault"
        #expect(MemoryText.openAction("\(vault)/a b.md", vault: vault)
            == .obsidian(URL(string: "obsidian://open?path=/Users/me/Vault/a%20b.md")!))
        for path in ["/Applications/Tool.app", "/Users/me/run.command", "/Users/me/x.dmg", "\(vault)/x.command"] {
            #expect(MemoryText.openAction(path, vault: vault) == .reveal(URL(fileURLWithPath: path)))
        }
    }

    @Test func pathsThatEscapeTheVaultAreNotVaultNotes() {
        let vault = "/Users/me/Vault"
        #expect(MemoryText.obsidianURL("\(vault)/../../etc/x.md", vault: vault) == nil)
        #expect(MemoryText.obsidianURL("\(vault)/a/../../JT-Vault-other/x.md", vault: vault) == nil)
        // `..` that stays inside the vault is resolved, not rejected.
        #expect(MemoryText.obsidianURL("\(vault)/a/../b.md", vault: vault)?.absoluteString
            == "obsidian://open?path=/Users/me/Vault/b.md")
        // A trailing slash on the setting changes nothing.
        #expect(MemoryText.obsidianURL("\(vault)/b.md", vault: vault + "/") != nil)
    }

    @Test func aVaultThatIsNotAnAbsolutePathMatchesNothing() {
        #expect(MemoryText.obsidianURL("/x/a.md", vault: "") == nil)
        #expect(MemoryText.obsidianURL("/x/a.md", vault: "/") == nil)
        #expect(MemoryText.obsidianURL("Obsidian/JT-Vault/a.md", vault: "Obsidian/JT-Vault") == nil)
        #expect(MemoryText.obsidianURL("~/Obsidian/JT-Vault/a.md", vault: "~/Obsidian/JT-Vault") == nil)
    }

    // MARK: One source down

    private nonisolated static let vaultBody = #"{"query":"q","results":[{"source":"vault","path":"/v/a.md","snippet":"s","score":0.9,"method":"fts"}]}"#
    private nonisolated static let sessionBody = #"{"query":"q","results":[{"path":"sessions/a.md","title":"T","snippet":null,"project":"p","workspace":"w","rank":1.5}]}"#

    /// `vaultStatus` / `sessionsStatus`: what the host answers on each route.
    private func client(vaultStatus: Int, sessionsStatus: Int) -> HostClient {
        HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil }, transport: { request in
            let isVault = request.url?.path() == "/api/memory/search"
            let status = isVault ? vaultStatus : sessionsStatus
            let body = status == 200 ? (isVault ? Self.vaultBody : Self.sessionBody) : #"{"detail":"down"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    /// Review focus: ai-memory down (host answers 502) must leave the vault hits on screen, with the reason.
    @Test func aDownSessionSourceKeepsTheVaultHits() async {
        let results = await MemoryResults.search("hermes", client: client(vaultStatus: 200, sessionsStatus: 502))
        #expect(results.vault.map(\.path) == ["/v/a.md"])
        #expect(results.sessions.isEmpty)
        #expect(results.error == "Sessions : down (HTTP 502).")
    }

    @Test func aDownVaultIndexKeepsTheSessionHits() async {
        let results = await MemoryResults.search("hermes", client: client(vaultStatus: 500, sessionsStatus: 200))
        #expect(results.vault.isEmpty)
        #expect(results.sessions.map(\.path) == ["sessions/a.md"])
        #expect(results.error == "Vault : down (HTTP 500).")
    }
}

/// The snippets of the vault index start with the note's YAML frontmatter, its newlines flattened to spaces
/// (`--- tags: [tech] status: imported --- # Title …`).
@Suite struct MemoryFrontmatterTests {
    @Test func aClosedFrontmatterBlockIsDropped() {
        let raw = "--- tags: [tech, outillage, imported] status: imported created: 2026-06-20 updated: 2026-08-04 --- # hermes chat (TUI) Le corps"
        #expect(MemoryText.stripFrontmatter(raw) == "# hermes chat (TUI) Le corps")
    }

    @Test func aBlockOnSeparateLinesIsDroppedToo() {
        #expect(MemoryText.stripFrontmatter("---\ntags: [a]\nstatus: x\n---\n# Titre\nCorps") == "# Titre\nCorps")
    }

    /// The snippet is short: cut inside the YAML, showing it would only show metadata.
    @Test func aSnippetCutInsideTheFrontmatterShowsNothing() {
        let raw = "--- tags: [trinavers, character, google-flow] status: active aliases: [Trinatosorus Rex] created: 2026-07-06 summary: Trinatosorus Rex — réf"
        #expect(MemoryText.stripFrontmatter(raw) == "")
        #expect(MemoryText.readable(raw) == "")
        #expect(MemoryText.stripFrontmatter("---") == "")
    }

    @Test func textWithoutFrontmatterIsUntouched() {
        for raw in ["# AgentOS v2 — Guide AgentOS is a local **governance**", "",
                    // A cut snippet starts with an ellipsis: a later `---` is a rule of the note, not YAML.
                    "…le début --- une règle --- la suite", "---- four dashes", "--dashes"] {
            #expect(MemoryText.stripFrontmatter(raw) == raw)
        }
    }

    @Test func theHighlightOfTheBodyIsKeptAndOnlyReadableRemovesIt() {
        let raw = "--- tags: [a] --- # Le <mark>Trinavers</mark> et <mark>Hermes</mark>"
        #expect(MemoryText.stripFrontmatter(raw) == "# Le <mark>Trinavers</mark> et <mark>Hermes</mark>")
        #expect(MemoryText.readable(raw) == "# Le Trinavers et Hermes")
    }

    @Test func aHighlightInsideTheFrontmatterGoesWithIt() {
        #expect(MemoryText.stripFrontmatter("--- engine: <mark>hermes</mark> profile: ask --- # Corps") == "# Corps")
    }

    @Test func onlyTheFirstBlockAndOnlyASeparatedRuleCloseIt() {
        #expect(MemoryText.stripFrontmatter("--- description: a---b status: x --- Corps --- reste") == "Corps --- reste")
        #expect(MemoryText.stripFrontmatter("  --- tags: [a] ---") == "")
    }
}

/// Sort by date: dated hits newest first, the others after them in the host's order.
@Suite struct MemorySortTests {
    private let old = Date(timeIntervalSince1970: 1_000)
    private let middle = Date(timeIntervalSince1970: 2_000)
    private let recent = Date(timeIntervalSince1970: 3_000)

    @Test func relevanceKeepsTheHostOrder() {
        let dates = ["a": old, "b": recent]
        #expect(MemorySort.relevance.ordered(["a", "b", "c"], date: { dates[$0] }) == ["a", "b", "c"])
    }

    @Test func dateOrdersNewestFirstAndUndatedFollowInTheirOwnOrder() {
        let dates = ["a": old, "c": recent, "e": middle]
        #expect(MemorySort.date.ordered(["a", "b", "c", "d", "e"], date: { dates[$0] }) == ["c", "e", "a", "b", "d"])
    }

    @Test func equalDatesKeepTheHostOrder() {
        let dates = ["a": middle, "b": middle, "c": middle]
        #expect(MemorySort.date.ordered(["b", "a", "c"], date: { dates[$0] }) == ["b", "a", "c"])
        #expect(MemorySort.date.ordered([String](), date: { _ in nil }).isEmpty)
    }

    @Test func choicesAreRelevanceThenDate() {
        #expect(MemorySort.allCases.map(\.label) == ["Pertinence", "Date"])
        #expect(MemorySource.allCases.map(\.label) == ["Tout", "Vault", "Sessions"])
    }
}

/// The date of a hit is its file's modification date: metadata only, the content is never read.
@Suite struct MemoryDateLookupTests {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "agentos-memory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aLocalFileGivesItsModificationDateEvenWhenItsContentIsUnreadable() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "note.md")
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        try Data("secret".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp, .posixPermissions: 0o000], ofItemAtPath: file.path)
        // mode 000: reading the content would fail, so a date proves only the metadata was asked for.
        #expect(!FileManager.default.isReadableFile(atPath: file.path))
        #expect(MemoryText.modificationDate(ofPath: file.path) == stamp)
    }

    @Test func aMissingFileARelativePathAndAnEmptyPathHaveNoDate() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MemoryText.modificationDate(ofPath: dir.appending(path: "gone.md").path) == nil)
        #expect(MemoryText.modificationDate(ofPath: "sessions/a.md") == nil)
        #expect(MemoryText.modificationDate(ofPath: "") == nil)
    }
}

/// Source filter and sort on the model, with an injected date lookup (no file is touched).
@MainActor @Suite struct MemoryFilterTests {
    let gate = Gate()

    private func client(slow: String = "none") -> HostClient {
        let gate = gate
        return HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil }, transport: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let key = items.first { $0.name == "q" }?.value ?? ""
            if key == slow { await gate.wait() }
            let body: String
            switch request.url?.path() {
            case "/api/memory/search":
                body = #"{"results":[{"source":"vault","path":"/v/\#(key)-a.md","snippet":null,"score":null,"method":"fts"},{"source":"claude","path":"/v/\#(key)-b.md","snippet":null,"score":null,"method":"fts"},{"source":"vault","path":"/v/\#(key)-c.md","snippet":null,"score":null,"method":"fts"}]}"#
            default:
                body = #"{"results":[{"path":"sessions/\#(key).md","title":"S","snippet":null,"project":"p","workspace":"w","rank":1.0}]}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func searched(dates: [String: Date] = [:]) async -> MemoryModel {
        let model = MemoryModel(dateLookup: { dates[$0] })
        model.search("hermes", client: client())
        await model.searchTask?.value
        return model
    }

    @Test func everythingByRelevanceIsTheDefault() async {
        let model = await searched()
        #expect(model.source == .all && model.sort == .relevance)
        #expect(model.shownVault.map(\.path) == ["/v/hermes-a.md", "/v/hermes-b.md", "/v/hermes-c.md"])
        #expect(model.shownSessions.map(\.path) == ["sessions/hermes.md"])
    }

    @Test func theSourceFilterShowsOneSectionOrBoth() async {
        let model = await searched()
        model.source = .vault
        #expect(model.shownVault.count == 3 && model.shownSessions.isEmpty && !model.isEmpty)
        model.source = .sessions
        #expect(model.shownVault.isEmpty && model.shownSessions.count == 1 && !model.isEmpty)
        model.source = .all
        #expect(model.shownVault.count == 3 && model.shownSessions.count == 1)
    }

    @Test func aFilterWithoutHitsIsEmptyEvenThoughTheOtherSourceHasSome() async {
        let model = MemoryModel(dateLookup: { _ in nil })
        model.search("hermes", client: client())
        await model.searchTask?.value
        model.source = .sessions
        model.search("hermes", client: HostClient(
            baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil }, transport: { request in
                (Data(#"{"results":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
        await model.searchTask?.value
        #expect(model.isEmpty && model.searched)
        #expect(model.emptyTitle == "Aucun résultat dans Sessions")
        model.source = .all
        #expect(model.emptyTitle == "Aucun résultat")
    }

    @Test func dateSortPutsTheNewestFirstAndKeepsTheUndatedAfterInHostOrder() async {
        let model = await searched(dates: ["/v/hermes-a.md": Date(timeIntervalSince1970: 100),
                                            "/v/hermes-c.md": Date(timeIntervalSince1970: 200)])
        model.sort = .date
        #expect(model.shownVault.map(\.path) == ["/v/hermes-c.md", "/v/hermes-a.md", "/v/hermes-b.md"])
        // Sessions have no date: unchanged.
        #expect(model.shownSessions.map(\.path) == ["sessions/hermes.md"])
        model.sort = .relevance
        #expect(model.shownVault.map(\.path) == ["/v/hermes-a.md", "/v/hermes-b.md", "/v/hermes-c.md"])
    }

    @Test func filterAndSortSurviveANewSearch() async {
        let model = await searched()
        model.source = .vault
        model.sort = .date
        model.search("trinavers", client: client())
        await model.searchTask?.value
        #expect(model.source == .vault && model.sort == .date)
        #expect(model.vault.first?.path == "/v/trinavers-a.md")
    }

    /// T9.4's guarantee still holds for the dates: a slower, older search never writes over the latest one.
    @Test func aSlowerOlderSearchNeverWritesItsDates() async {
        var asked: [String] = []
        let model = MemoryModel(dateLookup: { asked.append($0); return nil })
        let client = client(slow: "aaa")
        model.search("aaa", client: client)
        let older = model.searchTask
        model.search("bbb", client: client)
        await model.searchTask?.value
        #expect(asked.allSatisfy { $0.hasPrefix("/v/bbb") } && asked.count == 3)

        await gate.open()
        await older?.value
        #expect(asked.allSatisfy { $0.hasPrefix("/v/bbb") } && asked.count == 3)
        #expect(model.vault.map(\.path).allSatisfy { $0.hasPrefix("/v/bbb") })
    }
}

/// Holds a request until the test lets it go, to make the answer of an older request arrive last.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// The latest search / page click wins, whatever order the answers arrive in.
@MainActor @Suite struct MemoryModelTests {
    let gate = Gate()

    /// Requests whose `q` or `path` is `slow` wait for the gate; `failsWhenCancelled` makes them throw the way
    /// URLSession does when its task is cancelled.
    private func client(slow: String, failsWhenCancelled: Bool = false) -> HostClient {
        let gate = gate
        return HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil }, transport: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let key = items.first { $0.name == "q" || $0.name == "path" }?.value ?? ""
            if key == slow {
                await gate.wait()
                if failsWhenCancelled && Task.isCancelled { throw URLError(.cancelled) }
            }
            let body: String
            switch request.url?.path() {
            case "/api/memory/search":
                body = #"{"results":[{"source":"vault","path":"/v/\#(key).md","snippet":null,"score":null,"method":"fts"}]}"#
            case "/api/memory/page": body = #"{"path":"\#(key)","title":"page \#(key)","body":"b"}"#
            default: body = #"{"results":[]}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func aSlowerOlderSearchNeverReplacesTheLatestOne() async {
        let model = MemoryModel()
        let client = client(slow: "aaa")
        model.search("aaa", client: client)
        let older = model.searchTask
        model.search("bbb", client: client)
        await model.searchTask?.value
        #expect(model.vault.map(\.path) == ["/v/bbb.md"])

        await gate.open()  // the answer of "aaa" only arrives now
        await older?.value
        #expect(model.vault.map(\.path) == ["/v/bbb.md"])
    }

    @Test func aCancelledSearchDoesNotSurfaceAsAnError() async {
        let model = MemoryModel()
        let client = client(slow: "aaa", failsWhenCancelled: true)
        model.search("aaa", client: client)
        let older = model.searchTask
        model.search("bbb", client: client)
        await model.searchTask?.value
        await gate.open()
        await older?.value
        #expect(model.vault.map(\.path) == ["/v/bbb.md"])
        #expect(model.message == nil)
    }

    @Test func twoQuickClicksShowTheSecondPage() async {
        let model = MemoryModel()
        let client = client(slow: "sessions/a.md")
        let first = MemoryHit(path: "sessions/a.md", title: "A", snippet: nil, project: "p", workspace: "w", rank: nil)
        let second = MemoryHit(path: "sessions/b.md", title: "B", snippet: nil, project: "p", workspace: "w", rank: nil)
        model.show(first, client: client)
        let older = model.pageTask
        model.show(second, client: client)
        await model.pageTask?.value
        #expect(model.page?.path == "sessions/b.md")

        await gate.open()
        await older?.value
        #expect(model.page?.path == "sessions/b.md")
    }

    @Test func aFailedPageLoadShowsItsReasonAndTheNextSuccessClearsOnlyThat() async {
        let model = MemoryModel()
        let ok = MemoryHit(path: "sessions/b.md", title: "B", snippet: nil, project: "p", workspace: "w", rank: nil)
        let noScope = MemoryHit(path: "sessions/c.md", title: "C", snippet: nil, project: nil, workspace: nil, rank: nil)
        model.search("bbb", client: client(slow: "none"))
        await model.searchTask?.value
        model.show(noScope, client: client(slow: "none"))
        #expect(model.message == "Page : espace ou projet manquant dans le résultat.")
        model.show(ok, client: client(slow: "none"))
        await model.pageTask?.value
        #expect(model.page?.path == "sessions/b.md" && model.message == nil)
    }
}
