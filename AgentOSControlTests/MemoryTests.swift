import Foundation
import Testing
@testable import AgentOSControl

@Suite struct MemoryTests {
    @Test func snippetsLoseTheirMarkTags() {
        #expect(MemoryText.plain("…je développe le <mark>Trinavers</mark>, un…") == "…je développe le Trinavers, un…")
        #expect(MemoryText.fileName("/Users/jean/Obsidian/JT-Vault/08-Tech-Notes/hermes chat.md") == "hermes chat")
    }

    @Test func vaultNotesOpenInObsidianOtherFilesDoNot() {
        let vault = "/Users/jean/Obsidian/JT-Vault"
        let url = MemoryText.obsidianURL("\(vault)/08-Tech-Notes/x y.md", vault: vault)
        #expect(url?.absoluteString == "obsidian://open?path=/Users/jean/Obsidian/JT-Vault/08-Tech-Notes/x%20y.md")
        #expect(MemoryText.obsidianURL("/Users/jean/PyCharmMiscProject/infra/AgentOS/documents/a.md", vault: vault) == nil)
        #expect(MemoryText.obsidianURL("\(vault)-other/a.md", vault: vault) == nil)
    }

    /// Real vault names contain `+` (Cmd+maj+g sur finder.md); `+` must not be read back as a space.
    @Test func obsidianURLEscapesWhatWouldSplitTheQuery() {
        let vault = "/Users/jean/Obsidian/JT-Vault"
        let url = MemoryText.obsidianURL("\(vault)/08-Tech-Notes/Imported/Cmd+maj+g & é #1 100%.md", vault: vault)
        #expect(url?.absoluteString == "obsidian://open?path=/Users/jean/Obsidian/JT-Vault/08-Tech-Notes/Imported/Cmd%2Bmaj%2Bg%20%26%20%C3%A9%20%231%20100%25.md")
    }

    @Test func sessionHitsAreIdentifiedByWorkspaceProjectAndPath() throws {
        let json = #"{"path":"sessions/a.md","title":"T","snippet":null,"project":"p","workspace":"w","rank":null}"#
        let hit = try JSONDecoder().decode(MemoryHit.self, from: Data(json.utf8))
        #expect(hit.id == "w/p/sessions/a.md" && hit.snippet == nil && hit.rank == nil)
    }

    /// A note that is not under the vault is only ever revealed, never opened: `.app`, `.command`,
    /// `.dmg` and the like would launch. (`obsidianURL` is already nil for those.)
    @Test func onlyVaultNotesOpenEverythingElseIsRevealed() {
        let vault = "/Users/jean/Obsidian/JT-Vault"
        #expect(MemoryText.openAction("\(vault)/a b.md", vault: vault)
            == .obsidian(URL(string: "obsidian://open?path=/Users/jean/Obsidian/JT-Vault/a%20b.md")!))
        for path in ["/Applications/Tool.app", "/Users/jean/run.command", "/Users/jean/x.dmg", "\(vault)/x.command"] {
            #expect(MemoryText.openAction(path, vault: vault) == .reveal(URL(fileURLWithPath: path)))
        }
    }

    @Test func pathsThatEscapeTheVaultAreNotVaultNotes() {
        let vault = "/Users/jean/Obsidian/JT-Vault"
        #expect(MemoryText.obsidianURL("\(vault)/../../etc/x.md", vault: vault) == nil)
        #expect(MemoryText.obsidianURL("\(vault)/a/../../JT-Vault-other/x.md", vault: vault) == nil)
        // `..` that stays inside the vault is resolved, not rejected.
        #expect(MemoryText.obsidianURL("\(vault)/a/../b.md", vault: vault)?.absoluteString
            == "obsidian://open?path=/Users/jean/Obsidian/JT-Vault/b.md")
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
