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

    /// Review focus: ai-memory down (host answers 502) must leave the vault hits on screen, with the reason.
    @Test func aDownSourceKeepsTheOtherSourceHits() async {
        let vaultBody = #"{"query":"q","results":[{"source":"vault","path":"/v/a.md","snippet":"s","score":0.9,"method":"fts"}]}"#
        let client = HostClient(baseURL: URL(string: "http://127.0.0.1:3107")!, token: { nil }, transport: { request in
            let isVault = request.url?.path() == "/api/memory/search"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: isVault ? 200 : 502, httpVersion: nil, headerFields: nil)!
            return (Data((isVault ? vaultBody : #"{"detail":"ai-memory : down"}"#).utf8), response)
        })
        let results = await MemoryResults.search("hermes", client: client)
        #expect(results.vault.map(\.path) == ["/v/a.md"])
        #expect(results.sessions.isEmpty)
        #expect(results.error == "Sessions : Erreur HTTP 502.")
    }
}
