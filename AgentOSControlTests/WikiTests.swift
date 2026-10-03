import Foundation
import Testing
@testable import AgentOSControl

@Suite struct WikiTests {
    private let sample = """
        Anything before the first heading is ignored.

        # Sections

        ## Aperçu
        Line one.
        Line two, « quoted ».

        ## Runs
        Chaque exécution d'un agent.

        # Concepts

        ## Touch ID
        Tout passe par Touch ID.
        """

    @Test func parserCountsSectionsAndTopicsAndKeepsBodyLines() {
        let sections = WikiDocument.parse(sample)
        #expect(sections.map(\.title) == ["Sections", "Concepts"])
        #expect(sections.map { $0.topics.map(\.title) } == [["Aperçu", "Runs"], ["Touch ID"]])
        #expect(sections[0].topics[0].body == "Line one.\nLine two, « quoted ».")
        #expect(sections[1].topics[0].body == "Tout passe par Touch ID.")
    }

    @Test func parserIgnoresThePreambleAndAnUnclosedTopicWithoutASection() {
        #expect(WikiDocument.parse("just text\n## Orphan\nbody").isEmpty)
        #expect(WikiDocument.parse("").isEmpty)
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        let sections = WikiDocument.parse(sample)
        #expect(WikiDocument.search(sections, query: "apercu").flatMap(\.topics).map(\.title) == ["Aperçu"])
        #expect(WikiDocument.search(sections, query: "touch id").flatMap(\.topics).map(\.title) == ["Touch ID"])
        #expect(WikiDocument.search(sections, query: "APERÇU").flatMap(\.topics).map(\.title) == ["Aperçu"])
        #expect(WikiDocument.search(WikiDocument.parse("# S\n## Coup\nun coup d'œil"), query: "oeil").count == 1)
    }

    @Test func searchMatchesTheBodyAndDropsEmptySections() {
        let sections = WikiDocument.parse(sample)
        let hits = WikiDocument.search(sections, query: "exécution")
        #expect(hits.map(\.title) == ["Sections"])
        #expect(hits[0].topics.map(\.title) == ["Runs"])
        #expect(WikiDocument.search(sections, query: "zzz").isEmpty)
    }

    @Test func emptyQueryReturnsEverything() {
        let sections = WikiDocument.parse(sample)
        #expect(WikiDocument.search(sections, query: "") == sections)
        #expect(WikiDocument.search(sections, query: "  ") == sections)
    }

    @Test func renderedBodyKeepsQuotesAndLineBreaks() {
        let body = "Copier met la commande.\n« Lancer le scan » demande **Touch ID**."
        #expect(String(WikiText.rendered(body).characters) == "Copier met la commande.\n« Lancer le scan » demande Touch ID.")
    }

    @Test func missingResourceIsAnErrorNotAnEmptyWiki() throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "wiki-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = try #require(Bundle(url: empty))
        #expect(throws: WikiError.self) { try WikiDocument.load(from: bundle) }
    }

    /// The shipped Wiki.md: two sections, and a topic per sidebar section, so a new screen (SP8's
    /// `commands`) cannot ship without its fiche.
    @Test func bundledWikiCoversEverySidebarSection() throws {
        let sections = try WikiDocument.load(from: .main)
        #expect(sections.map(\.title) == ["Sections", "Concepts"])
        let topics = sections.flatMap(\.topics)
        let titles = topics.map(\.title)
        #expect(Set(titles).count == titles.count, "topic titles must be unique (they key the expanded state)")
        #expect(topics.allSatisfy { !$0.body.isEmpty })
        for item in SidebarItem.allCases where item != .wiki {
            #expect(titles.contains(item.title), "Wiki.md needs a « \(item.title) » topic")
        }
    }

    /// The SP8 fiches name a command line and a folder: the Markdown rendering must not eat `<run>` or `_a-trier`.
    @Test func dialogueAndCleanupFichesKeepTheirLiteralTokens() throws {
        let topics = try WikiDocument.load(from: .main).flatMap(\.topics)
        let shown = { (title: String) -> String in
            String(WikiText.rendered(topics.first { $0.title == title }?.body ?? "").characters)
        }
        #expect(shown("Dialogue en direct").contains("agentos tail <run> --claude"))
        #expect(shown("Ménage").contains("dans _a-trier."))
        #expect(topics.map(\.title).contains("Arbitre") && topics.map(\.title).contains("Mini-bots Haiku"))
    }
}
