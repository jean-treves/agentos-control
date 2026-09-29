import Foundation
import os

/// One fiche: a title and a few lines.
struct WikiTopic: Identifiable, Hashable {
    let title: String
    let body: String
    var id: String { title }
}

/// A group of fiches under one header.
struct WikiSection: Identifiable, Hashable {
    let title: String
    let topics: [WikiTopic]
    var id: String { title }
}

enum WikiError: LocalizedError {
    case missing

    var errorDescription: String? { "Wiki.md est introuvable dans l'app." }
}

/// The Wiki screen's text (`Resources/Wiki.md`): `# ` starts a section, `## ` a topic, the lines after it
/// are the topic's body.
enum WikiDocument {
    private static let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "wiki")

    /// The shipped file, read once. A missing or unreadable file is an error the screen shows, never an
    /// empty wiki.
    static let bundled: Result<[WikiSection], Error> = {
        do {
            return .success(try load(from: .main))
        } catch {
            logger.error("Wiki.md not loaded: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }()

    static func load(from bundle: Bundle) throws -> [WikiSection] {
        guard let url = bundle.url(forResource: "Wiki", withExtension: "md") else { throw WikiError.missing }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// Text before the first `# ` and lines of a section before its first `## ` belong to no topic: ignored.
    static func parse(_ markdown: String) -> [WikiSection] {
        var done: [WikiSection] = []
        var section: (title: String, topics: [WikiTopic])?
        var topic: (title: String, lines: [Substring])?

        func closeTopic() {
            guard let open = topic else { return }
            let body = open.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            section?.topics.append(WikiTopic(title: open.title, body: body))
            topic = nil
        }
        func closeSection() {
            closeTopic()
            if let open = section { done.append(WikiSection(title: open.title, topics: open.topics)) }
            section = nil
        }

        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("# ") {
                closeSection()
                section = (line.dropFirst(2).trimmingCharacters(in: .whitespaces), [])
            } else if line.hasPrefix("## "), section != nil {
                closeTopic()
                topic = (line.dropFirst(3).trimmingCharacters(in: .whitespaces), [])
            } else {
                topic?.lines.append(line)
            }
        }
        closeSection()
        return done
    }

    /// Topics whose title or body contains `query`, ignoring case and diacritics; sections left empty
    /// disappear. A blank query keeps everything.
    static func search(_ sections: [WikiSection], query: String) -> [WikiSection] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.topics.filter { fold($0.title).contains(needle) || fold($0.body).contains(needle) }
            return hits.isEmpty ? nil : WikiSection(title: section.title, topics: hits)
        }
    }

    /// "œ" does not decompose, so "oeil" would not find "œil" without the explicit replacement.
    private static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "Œ", with: "OE")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

enum WikiText {
    private static let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "wiki")

    /// Inline Markdown only, whitespace kept: « » quotes and line breaks survive as written.
    static func rendered(_ body: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            logger.error("Markdown not rendered, shown as plain text: \(error.localizedDescription, privacy: .public)")
            return AttributedString(body)
        }
    }
}
