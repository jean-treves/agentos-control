import SwiftUI

extension DelegationCard {
    /// The card as the host seals it (`kernel/delegation.card`): the review freezes this copy, so what JT reads is
    /// what the brief says, byte for byte. Title, project, verify and the choices are one line, the three texts
    /// keep their lines.
    nonisolated func cleaned() -> DelegationCard {
        DelegationCard(
            title: title.hostCleaned(oneLine: true), project: project.hostCleaned(oneLine: true),
            goal: goal.hostCleaned(oneLine: false), context: context.hostCleaned(oneLine: false),
            doneWhen: doneWhen.hostCleaned(oneLine: false), verify: verify.hostCleaned(oneLine: true),
            outputMode: outputMode.hostCleaned(oneLine: true), agenticMode: agenticMode.hostCleaned(oneLine: true),
            executorModel: executorModel.hostCleaned(oneLine: true), sonnetEffort: sonnetEffort.hostCleaned(oneLine: true))
    }
}

/// What JT reads before « Déléguer » (decision D34): « Déléguer » creates, seals and launches every brief in
/// one host call, so each card is shown in full, as plain text, before Touch ID. Pure data: a test drives it.
nonisolated struct DelegationReview: Equatable, Sendable {
    /// The host takes these two (kernel/briefs.OUTPUT_MODES minus `yolo`); anything else is not sent.
    static let allowedOutputModes = ["diagnostic", "pr"]

    nonisolated struct Field: Equatable, Sendable {
        let label: String
        let value: String
        var isAlert = false
    }

    nonisolated struct Entry: Equatable, Sendable, Identifiable {
        let id: Int
        let heading: String
        let fields: [Field]
    }

    /// The cleaned cards: the only ones that can be sent from this review.
    let cards: [DelegationCard]
    /// The number of the cards at the moment they were shown (`ConversationDetail.cardsSeq`), sent back with them.
    let cardsSeq: Int?
    let entries: [Entry]

    init(cards: [DelegationCard], cardsSeq: Int?, options: ConversationOptions) {
        self.cards = cards.map { $0.cleaned() }
        self.cardsSeq = cardsSeq
        entries = self.cards.enumerated().map { index, card in
            Self.entry(card, number: index + 1, of: cards.count, options: options)
        }
    }

    var blockers: [String] { Self.blockers(for: cards) }

    /// Why these cards must not be sent at all (a mode the host refuses, or nothing to send). The host checks
    /// again; this stops before Touch ID.
    static func blockers(for cards: [DelegationCard]) -> [String] {
        if cards.isEmpty { return ["aucune carte à déléguer."] }
        return cards.enumerated().compactMap { index, card in
            guard !allowedOutputModes.contains(card.outputMode) else { return nil }
            let mode = String(card.outputMode.plainText().prefix(40))
            return "carte \(index + 1) : le mode de sortie « \(mode) » est refusé (seuls diagnostic et pr se délèguent)"
        }
    }

    /// What Touch ID says: how many briefs start.
    static func touchIDReason(count: Int) -> String { "lancer \(count) brief(s) délégué(s)" }

    private static func entry(_ card: DelegationCard, number: Int, of total: Int,
                              options: ConversationOptions) -> Entry {
        let refused = !allowedOutputModes.contains(card.outputMode)
        let emptyVerify = card.verify.trimmingCharacters(in: .whitespaces).isEmpty
        let fields = [
            Field(label: "Projet", value: card.project),
            Field(label: "Vérification",
                  value: emptyVerify ? "(vide : le host refusera ce brief)" : card.verify, isAlert: emptyVerify),
            Field(label: "Mode de sortie", value: labelled(card.outputMode, options.outputModes), isAlert: refused),
            Field(label: "Mode agentique", value: labelled(card.agenticMode, options.agenticModes)),
            Field(label: "Modèle de l'exécutant", value: card.executorModel),
            Field(label: "Effort de Sonnet", value: card.sonnetEffort),
            Field(label: "Objectif", value: card.goal),
            Field(label: "Contexte", value: card.context.isEmpty ? "—" : card.context),
            Field(label: "Critère de fin", value: card.doneWhen),
        ]
        return Entry(id: number, heading: "Brief \(number)/\(total) : \(card.title)" + (refused ? " (refusé)" : ""),
                     fields: fields)
    }

    /// « Essai + PR (pr) »: the label and the value that is sent; a value the host gave no label for stays alone.
    private static func labelled(_ value: String, _ labels: [String: String]) -> String {
        labels[value].map { "\($0.plainText()) (\(value))" } ?? value
    }
}

/// The two steps of « Déléguer »: the review, then Touch ID and the one host call. Apart from the view so that
/// a test drives the path the sheet takes.
@Observable
final class DelegationFlow {
    /// Set while JT reads the cards; nil otherwise. Nothing is sent without it.
    private(set) var review: DelegationReview?
    private(set) var sending = false
    /// The host's account of a delegation that went through.
    private(set) var reply: DelegationReply?
    /// Why the last step did nothing (Touch ID not confirmed, the host's refusal, an answer that never came).
    private(set) var problem: String?

    /// Shows the cards; sends nothing. `cardsSeq`: the number of these cards, kept for the one host call.
    func begin(cards: [DelegationCard], cardsSeq: Int?, options: ConversationOptions) {
        guard !sending else { return }
        reply = nil
        problem = nil
        review = DelegationReview(cards: cards, cardsSeq: cardsSeq, options: options)
    }

    func cancel() {
        guard !sending else { return }
        review = nil
    }

    /// Closes a review whose cards are no longer the host's (another number): confirming it would delegate
    /// what JT read, but the screen behind has moved on. Never while the call is in flight. True when closed.
    @discardableResult
    func closeIfStale(cardsSeq: Int?) -> Bool {
        guard let review, !sending, review.cardsSeq != cardsSeq else { return false }
        self.review = nil
        return true
    }

    /// Touch ID, then the reviewed cards. A second click while the first is in flight does nothing, and the review
    /// is gone once the host answered, so a click after the answer sends nothing either. A refused Touch ID keeps
    /// the review open; a refusal by the host (or an answer that never came) closes it: the cards stay editable,
    /// and the next poll shows whether the host cleared them.
    func confirm(_ id: String, using model: ControlModel) async {
        guard let review, !sending else { return }
        sending = true
        defer { sending = false }
        problem = nil
        if let sent = await model.delegate(id, cards: review.cards, cardsSeq: review.cardsSeq) {
            reply = sent
        } else if model.lastError == nil {
            problem = ControlModel.notConfirmed
            return
        } else {
            problem = model.lastError
        }
        self.review = nil
    }
}

/// The confirmation step of « Déléguer »: every card in full, then Touch ID.
struct DelegationSheet: View {
    let flow: DelegationFlow
    let confirm: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relecture avant de déléguer").font(.headline)
            Text("Déléguer crée, valide et lance chaque brief en une seule étape. Rien n'est envoyé avant ta confirmation (Touch ID).")
                .font(.caption).foregroundStyle(.secondary)
            if let review = flow.review {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(review.entries) { entry in DelegationEntryView(entry: entry) }
                    }
                }
                ForEach(review.blockers, id: \.self) { blocker in
                    Text(verbatim: blocker).font(.caption.bold()).foregroundStyle(.red)
                }
            }
            if let problem = flow.problem { Text(verbatim: problem.plainText()).font(.caption).textSelection(.enabled) }
            if flow.sending { ProgressView("Le host crée, valide et lance les briefs…") }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 440)
        .interactiveDismissDisabled(flow.sending)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler") { flow.cancel(); dismiss() }.disabled(flow.sending)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle) { Task { await confirm() } }
                    .disabled(flow.sending || flow.review.map { !$0.blockers.isEmpty } != false)
            }
        }
    }

    private var confirmTitle: String {
        "Confirmer : lancer \(flow.review?.cards.count ?? 0) brief(s) (Touch ID)"
    }
}

/// One card of the review, plain text only.
struct DelegationEntryView: View {
    let entry: DelegationReview.Entry

    var body: some View {
        GroupBox {
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(entry.fields, id: \.label) { field in
                    GridRow {
                        Text(verbatim: field.label).foregroundStyle(.secondary)
                        Text(verbatim: field.value)
                            .fontWeight(field.isAlert ? .bold : .regular)
                            .foregroundStyle(field.isAlert ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.callout)
            .padding(2)
        } label: {
            Text(verbatim: entry.heading).font(.headline)
                .foregroundStyle(entry.heading.hasSuffix("(refusé)") ? Color.red : Color.primary)
        }
    }
}

/// One delegation card, every field editable except the project (a conversation delegates inside the project it
/// was opened on; the host refuses another). The host checks them all again; « Déléguer » shows them in full.
struct CardEditor: View {
    @Binding var card: DelegationCard
    let options: ConversationOptions

    var body: some View {
        GroupBox {
            Form {
                TextField("Titre", text: $card.title)
                LabeledContent("Projet") { Text(verbatim: card.project.plainText()).textSelection(.enabled) }
                TextField("Objectif", text: $card.goal, axis: .vertical)
                TextField("Contexte", text: $card.context, axis: .vertical)
                TextField("Critère de fin", text: $card.doneWhen, axis: .vertical)
                TextField("Vérification (une commande)", text: $card.verify)
                Picker("Mode de sortie", selection: $card.outputMode) {
                    choices(options.outputModes, current: card.outputMode, only: DelegationReview.allowedOutputModes)
                }
                Picker("Mode agentique", selection: $card.agenticMode) {
                    choices(options.agenticModes, current: card.agenticMode)
                }
                Picker("Modèle de l'exécutant", selection: $card.executorModel) {
                    values(options.executorModels, current: card.executorModel)
                }
                Picker("Effort de Sonnet", selection: $card.sonnetEffort) {
                    values(options.efforts, current: card.sonnetEffort)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The host's labelled choices (only `only`, when given), plus the card's own value if it is none of them:
    /// a picker with no row for its value shows a blank, which would hide what the card says.
    private func choices(_ labels: [String: String], current: String, only: [String]? = nil) -> some View {
        let keys = labels.keys.filter { only?.contains($0) ?? true }.sorted()
        return ForEach(keys + (keys.contains(current) ? [] : [current]), id: \.self) { key in
            Text(verbatim: (labels[key] ?? key).plainText() + (only?.contains(key) == false ? " (refusé)" : "")).tag(key)
        }
    }

    private func values(_ options: [String], current: String) -> some View {
        ForEach(options + (options.contains(current) ? [] : [current]), id: \.self) { value in
            Text(verbatim: value.plainText()).tag(value)
        }
    }
}
