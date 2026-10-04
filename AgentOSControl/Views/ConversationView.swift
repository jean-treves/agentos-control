import SwiftUI

/// Conversation with Sonnet (spec §17.13, H10, H11): one chat per project and mode, the reply streamed from
/// the transcript, delegation cards JT edits, « Déléguer » (a review of every card, then Touch ID) and
/// « Promouvoir » (Touch ID). Opening and sending need the control token only: nothing leaves the conversation
/// without one of the two buttons.
struct ConversationView: View {
    @Environment(ControlModel.self) private var model
    @State private var index: ConversationIndex?
    @State private var selected: String?
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            Group {
                if let selected, let options = index?.options {
                    ConversationDetailView(id: selected, options: options).id(selected)
                } else {
                    ContentUnavailableView("Ouvre ou choisis une conversation",
                                           systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $creating) {
            if let options = index?.options {
                NewConversationSheet(options: options) { id in
                    selected = id
                    Task { await load() }
                }
            }
        }
        .task { await pollEvery(.seconds(10)) { await load() } }
    }

    private var sidebar: some View {
        List(index?.conversations ?? [], selection: $selected) { conversation in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: conversation.title.plainText()).lineLimit(1)
                Text(verbatim: [conversation.project.plainText(),
                                (index?.options.modes[conversation.mode] ?? conversation.mode).plainText(),
                                conversation.busy ? "Sonnet répond…" : "\(conversation.turns) tour(s)"]
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(conversation.id)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let quota = index?.quota { QuotaText(quota: quota) }
                Button("Nouvelle conversation…") { creating = true }.disabled(index == nil)
                if let error { Text(verbatim: error.plainText()).font(.caption).foregroundStyle(.red) }
            }
            .padding(8)
        }
    }

    private func load() async {
        do {
            index = try await model.client.conversations()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func color(_ quota: QuotaInfo) -> Color {
        switch quota.state {
        case "exhausted": .red
        case "warn": .orange
        default: .secondary
        }
    }
}

/// The 5-hour window the host reports: how much is used and when it reopens.
struct QuotaText: View {
    let quota: QuotaInfo

    var body: some View {
        Text(verbatim: [quota.line, quota.resetNote()].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(ConversationView.color(quota))
    }
}

/// Project and mode are chosen once (spec §17.13); the first message starts the Claude session.
struct NewConversationSheet: View {
    let options: ConversationOptions
    let opened: (String) -> Void
    @Environment(ControlModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var mode = "read"
    @State private var effort = "medium"  // H4: JT sets Sonnet's effort per conversation
    @State private var text = ""
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        Form {
            Picker("Projet", selection: $project) {
                ForEach(options.projects, id: \.self) { Text(verbatim: $0.plainText()).tag($0) }
            }
            Picker("Mode", selection: $mode) {
                ForEach(ConversationOptions.modeOrder, id: \.self) {
                    Text(verbatim: (options.modes[$0] ?? $0).plainText()).tag($0)
                }
            }
            .pickerStyle(.radioGroup)
            Picker("Effort de Sonnet", selection: $effort) {
                ForEach(options.efforts, id: \.self) { Text(verbatim: $0.plainText()).tag($0) }
            }
            Text(mode == "modify"
                 ? "Sonnet écrit dans un worktree créé pour la conversation ; chaque demande d'autorisation vient dans Approbations ; rien n'entre dans le projet sans Promouvoir (Touch ID)."
                 : "Sonnet lit le projet, le vault et la mémoire, et n'écrit rien.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Premier message")
                TextEditor(text: $text).frame(minHeight: 120)
            }
            if let error { Text(verbatim: error.plainText()).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 400)
        .onAppear { project = options.projects.first ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() }.disabled(sending) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ouvrir") { Task { await open() } }
                    .disabled(sending || project.isEmpty
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func open() async {
        guard !sending else { return }  // a double click opens one conversation
        sending = true
        defer { sending = false }
        do {
            let started = try await model.client.openConversation(project: project, mode: mode, effort: effort,
                                                                  message: text)
            opened(started.id)
            dismiss()
        } catch {
            self.error = error.descriptionAfterSend
        }
    }
}

/// One conversation: the transcript (live, `/ws/conversations/{id}`), the delegation cards, the composer. The
/// detail is polled every 3 s for `busy`, the quota and new cards; JT's card edits survive the polling until the
/// host sends different cards.
struct ConversationDetailView: View {
    let id: String
    let options: ConversationOptions
    @Environment(ControlModel.self) private var model
    @State private var session: ConversationSession
    @State private var buffer = DialogueBuffer()
    @State private var draft = ""
    @State private var sending = false
    @State private var promoting = false

    init(id: String, options: ConversationOptions) {
        self.id = id
        self.options = options
        _session = State(initialValue: ConversationSession(id: id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ConversationTranscript(buffer: buffer)
            if !session.edits.items.isEmpty || session.detail?.cardsError != nil { cardsPanel }
            composer
            if let note = session.note {
                Text(verbatim: note.plainText()).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(8)
        .task { await pollEvery(.seconds(3)) { await session.reload(using: model.client) } }
        .task {
            let socket = DialogueSocket(url: DialogueSocket.conversationURL(for: model.client.baseURL, id: id),
                                        maxTextLength: DialogueLine.transcriptTextLength)
            for await event in socket.events() { buffer.apply(event) }
        }
        .sheet(isPresented: Binding(get: { session.flow.review != nil }, set: { if !$0 { session.flow.cancel() } })) {
            DelegationSheet(flow: session.flow) { await session.delegate(using: model) }
        }
    }

    @ViewBuilder private var header: some View {
        if let detail = session.detail {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(detail.project) · \(options.modes[detail.mode] ?? detail.mode)".plainText())
                        .font(.headline)
                    QuotaText(quota: detail.quota)
                }
                Spacer()
                if detail.mode == "modify" {
                    Button("Promouvoir (Touch ID)") { Task { await promote() } }
                        .disabled(detail.busy || promoting)
                }
            }
        } else if let loadError = session.loadError {
            Text(verbatim: loadError.plainText()).font(.caption).foregroundStyle(.red)
        }
    }

    private var cardsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = session.detail?.cardsError {
                Text(verbatim: error.plainText()).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(session.edits.items) { item in
                        CardEditor(card: session.binding(for: item.id), options: options)
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                // Nothing is sent from here: the button opens the review of every card.
                Button("Déléguer \(session.edits.items.count) tâche(s)…") { session.beginReview(options: options) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.edits.items.isEmpty || session.flow.sending)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextEditor(text: $draft)
                .frame(minHeight: 44, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Button(sendTitle) { Task { await send() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || !Self.canSend(session.detail, draft: draft))
        }
    }

    private var sendTitle: String {
        if session.detail?.busy == true { return "Sonnet répond…" }
        return session.detail?.quota.state == "exhausted" ? "Quota épuisé" : "Envoyer"
    }

    /// Nothing is sent while Sonnet answers or once the quota is spent (spec §17.13).
    static func canSend(_ detail: ConversationDetail?, draft: String) -> Bool {
        guard let detail else { return false }
        return !detail.busy && detail.quota.state != "exhausted"
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What an empty transcript says: it holds messages, not a run's lines.
    static func emptyNote(_ note: PaneNote) -> String {
        note == .connecting ? "connexion…" : "aucun message"
    }

    private func send() async {
        guard !sending else { return }  // a double click sends one message
        sending = true
        defer { sending = false }
        do {
            _ = try await model.client.sendMessage(id, text: draft)
            draft = ""
            session.note = nil
        } catch {
            session.note = error.descriptionAfterSend
        }
        await session.reload(using: model.client)
    }

    private func promote() async {
        guard !promoting else { return }
        promoting = true
        defer { promoting = false }
        if let reply = await model.promoteConversation(id) {
            session.note = "Promu dans \(reply.branch) (\(reply.head))"
        } else {
            session.note = model.failureReason
        }
        await session.reload(using: model.client)
    }
}

/// The transcript of a conversation: JT's lines on the right, Sonnet's on the left, tool calls and AgentOS notes as
/// small terminal lines. It follows its end until JT scrolls up to read.
struct ConversationTranscript: View {
    let buffer: DialogueBuffer
    @State private var follow = ScrollFollow()
    @State private var position = ScrollPosition()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Button(copied ? "Copié" : "Copier", action: copy)
                    .controlSize(.small).disabled(buffer.lines.isEmpty)
                    .help("Copie toute la transcription en texte brut")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(buffer.numbered) { row in TranscriptLine(line: row.line) }
                }
                .padding(4)
            }
            .followsEnd($follow, position: $position)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if let note = buffer.note {
                    Text(verbatim: ConversationDetailView.emptyNote(note)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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

/// One transcript line. Everything in it is text from outside: plain `Text(verbatim:)`, never Markdown or a link.
struct TranscriptLine: View {
    let line: DialogueLine

    enum Kind: Equatable {
        case mine, reply, note

        /// The roles the host writes (`kernel/conversations`): `jt`, `sonnet`; `outil` and `agentos` are notes.
        /// Any other role, a forged one included, is a note: never a bubble.
        init(role: String) {
            switch role {
            case "jt": self = .mine
            case "sonnet": self = .reply
            default: self = .note
            }
        }
    }

    var body: some View {
        switch Kind(role: line.role) {
        case .mine:
            HStack { Spacer(minLength: 80); bubble(Color.accentColor.opacity(0.15), alignment: .trailing) }
        case .reply:
            HStack { bubble(Color.secondary.opacity(0.12), alignment: .leading); Spacer(minLength: 80) }
        case .note:
            DialogueRow(line: line).textSelection(.enabled)
        }
    }

    private func bubble(_ fill: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(verbatim: line.text)
                .textSelection(.enabled)
                .padding(8)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
            Text(verbatim: "\(line.clock()) \(line.role)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
