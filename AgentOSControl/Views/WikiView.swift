import SwiftUI

/// Wiki: short fiches on every screen and concept, from the bundled `Wiki.md`. Collapsed by default;
/// a search opens the fiches it finds.
struct WikiView: View {
    @State private var query: String
    @State private var expanded: Set<String>

    init(query: String = "") {
        _query = State(initialValue: query)
        _expanded = State(initialValue: Self.opened(by: query, in: (try? WikiDocument.bundled.get()) ?? []))
    }

    var body: some View {
        switch WikiDocument.bundled {
        case .success(let sections): content(sections)
        case .failure(let error):
            ContentUnavailableView(
                "Wiki indisponible", systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription))
        }
    }

    private func content(_ all: [WikiSection]) -> some View {
        let shown = WikiDocument.search(all, query: query)
        return List {
            ForEach(shown) { section in
                Section(section.title) {
                    ForEach(section.topics) { topic in
                        DisclosureGroup(topic.title, isExpanded: isExpanded(topic)) {
                            Text(WikiText.rendered(topic.body))
                                .frame(maxWidth: 560, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Chercher une fiche")
        .onChange(of: query) {
            expanded = Self.opened(by: query, in: all)
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(
                    "Aucune fiche", systemImage: "magnifyingglass",
                    description: Text("Rien ne correspond à « \(query) »."))
            }
        }
    }

    /// While searching, every hit is open; with no search, everything is folded.
    private static func opened(by query: String, in all: [WikiSection]) -> Set<String> {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Set(WikiDocument.search(all, query: query).flatMap(\.topics).map(\.id))
    }

    private func isExpanded(_ topic: WikiTopic) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(topic.id) },
            set: { if $0 { expanded.insert(topic.id) } else { expanded.remove(topic.id) } })
    }
}
