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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer()
                Text(verbatim: follow.isFollowing ? "suivi" : "suivi suspendu").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                // Plain `Text(verbatim:)`: a line is whatever a tool printed, never Markdown or a link.
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(buffer.numbered) { row in
                        Text(verbatim: "\(row.line.clock) \(row.line.role) │ \(row.line.text)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(4)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollFollow.Metrics.self) { geometry in
                ScrollFollow.Metrics(bottomEdge: geometry.visibleRect.maxY, viewport: geometry.containerSize.height,
                                     content: geometry.contentSize.height)
            } action: { old, new in
                follow.scrolled(from: old, to: new)
                // Driven by the layout, not by the data: a burst of lines (the backlog) is laid out after
                // it arrived, and `scrollTo(edge:)` asked for the edge JT is already at moves nothing.
                if follow.isFollowing, new.content - new.bottomEdge > ScrollFollow.slack {
                    position.scrollTo(y: max(0, new.content - new.viewport))
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(6)
        .frame(minWidth: 240)
    }
}
