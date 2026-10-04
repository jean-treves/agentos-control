import SwiftUI

/// Two read-only terminals side by side (spec §17.7, H9): Claude (conversation, arbiter, reviewer) and
/// Hermès (the executor). Auto-scroll stops as soon as JT scrolls up, and resumes at the bottom.
/// The sockets open with the view, so only while it is shown.
struct DialogueView: View {
    let runID: String
    @Environment(ControlModel.self) private var model

    var body: some View {
        HSplitView {
            DialoguePaneView(baseURL: model.client.baseURL, runID: runID, pane: .claude)
            DialoguePaneView(baseURL: model.client.baseURL, runID: runID, pane: .hermes)
        }
    }
}

/// One pane: the socket feeds a buffer, a terminal shows it.
struct DialoguePaneView: View {
    let baseURL: URL
    let runID: String
    let pane: DialoguePane
    @State private var buffer = DialogueBuffer()

    var body: some View {
        DialogueTerminal(title: pane.title, buffer: buffer)
            .task {
                for await event in DialogueSocket(baseURL: baseURL, runID: runID, pane: pane).events() {
                    buffer.apply(event)
                }
            }
    }
}

/// The lines of a buffer as a terminal: monospaced, selectable, following its end until JT scrolls up.
struct DialogueTerminal: View {
    let title: String
    let buffer: DialogueBuffer
    @State private var follow = ScrollFollow()
    @State private var position = ScrollPosition()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer()
                Text(verbatim: follow.isFollowing ? "suivi" : "suivi suspendu").font(.caption).foregroundStyle(.secondary)
                Button(copied ? "Copié" : "Copier", action: copy)
                    .controlSize(.small).disabled(buffer.lines.isEmpty)
                    .help("Copie tout le volet en texte brut")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(buffer.numbered) { row in
                        DialogueRow(line: row.line)
                    }
                }
                .textSelection(.enabled)
                .padding(4)
            }
            .followsEnd($follow, position: $position)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if let note = buffer.note { Text(verbatim: note.text).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(6)
        .frame(minWidth: 240)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buffer.copyText(), forType: .string)
        copied = true
    }
}

extension View {
    /// A scroll view that follows its end until JT scrolls up and resumes when he comes back to it
    /// (`ScrollFollow`): a pane and a conversation's transcript share it.
    func followsEnd(_ follow: Binding<ScrollFollow>, position: Binding<ScrollPosition>) -> some View {
        scrollPosition(position)
            .onScrollGeometryChange(for: ScrollFollow.Metrics.self) { geometry in
                ScrollFollow.Metrics(bottomEdge: geometry.visibleRect.maxY, viewport: geometry.containerSize.height,
                                     content: geometry.contentSize.height)
            } action: { old, new in
                follow.wrappedValue.scrolled(from: old, to: new)
                // Driven by the layout, not by the data: a burst of lines (the backlog) is laid out after
                // it arrived, and `scrollTo(edge:)` asked for the edge JT is already at moves nothing.
                if follow.wrappedValue.isFollowing, new.content - new.bottomEdge > ScrollFollow.slack {
                    position.wrappedValue.scrollTo(y: max(0, new.content - new.viewport))
                }
            }
    }
}

/// One line: the header (clock, role) and the body are two texts side by side. The body is what a tool printed
/// and may hold a new line; its next line stays under the body and never starts at the left edge, where a
/// forged « 12:00:07 agentos │ … » would pass for a real header.
struct DialogueRow: View {
    let line: DialogueLine

    var body: some View {
        // Plain `Text(verbatim:)`: a line is whatever a tool printed, never Markdown or a link.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: line.header()).fixedSize()
            Text(verbatim: line.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
