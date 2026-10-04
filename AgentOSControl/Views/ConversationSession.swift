import SwiftUI

extension DelegationCard {
    /// What a binding answers for a card that is no longer in the list.
    nonisolated static let empty = DelegationCard(
        title: "", project: "", goal: "", context: "", doneWhen: "", verify: "", outputMode: "", agenticMode: "",
        executorModel: "", sonnetEffort: "")
}

/// A card in the editor, with an identity of its own: the position in the list changes whenever the host
/// sends other cards or the list is emptied, an editor's binding must not.
nonisolated struct EditableCard: Identifiable, Equatable, Sendable {
    let id = UUID()
    var card: DelegationCard
}

/// The cards JT edits. Every write goes through an id: a write for a card that is gone is dropped, never
/// applied to another one (a field editor writes back when its edit ends, after its row has disappeared).
nonisolated struct CardEdits: Equatable, Sendable {
    private(set) var items: [EditableCard]

    init(_ cards: [DelegationCard] = []) { items = cards.map { EditableCard(card: $0) } }

    var cards: [DelegationCard] { items.map(\.card) }

    func card(_ id: UUID) -> DelegationCard? { items.first { $0.id == id }?.card }

    mutating func set(_ id: UUID, to card: DelegationCard) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].card = card
    }

    /// The host's cards (or none): every card gets a new identity.
    mutating func replace(with cards: [DelegationCard]) { self = CardEdits(cards) }
}

/// What one open conversation knows and does: the host's detail, the cards JT edits, the review and the one
/// host call of « Déléguer ». Apart from the view so that a test drives the paths the view takes.
@Observable
final class ConversationSession {
    let id: String
    private(set) var detail: ConversationDetail?
    private(set) var edits = CardEdits()
    private(set) var loadError: String?
    /// The last thing worth telling JT (a delegation, a promotion, a refusal).
    var note: String?
    let flow = DelegationFlow()

    init(id: String) { self.id = id }

    /// The editor of one card. By id, never by position: a binding that outlives its card answers an empty
    /// card and drops the write.
    func binding(for card: UUID) -> Binding<DelegationCard> {
        Binding(get: { self.edits.card(card) ?? .empty }, set: { self.edits.set(card, to: $0) })
    }

    /// Shows the cards in full; sends nothing.
    func beginReview(options: ConversationOptions) {
        flow.begin(cards: edits.cards, cardsSeq: detail?.cardsSeq, options: options)
    }

    /// Polls the detail. JT's edits survive until the host sends different cards (another content or another
    /// `cards_seq`: the same cards again are new cards). `adopting`: the host's cards replace the editor's whatever
    /// they are, after a delegation the host answered.
    func reload(using client: HostClient, adopting: Bool = false) async {
        do {
            let fresh = try await client.conversation(id)
            let changed = fresh.cards != detail?.cards || fresh.cardsSeq != detail?.cardsSeq
            if changed || adopting { edits.replace(with: fresh.cards) }
            if changed, flow.closeIfStale(cardsSeq: fresh.cardsSeq) {
                note = "Sonnet a envoyé de nouvelles cartes : relis-les avant de déléguer."
            }
            detail = fresh
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Runs when JT confirms the review: Touch ID, the one host call, then what the host says.
    func delegate(using model: ControlModel) async {
        await flow.confirm(id, using: model)
        let answered = flow.reply
        if let reply = answered {
            edits.replace(with: [])  // the host cleared them; a second delegation would be a duplicate
            note = "Délégué : " + reply.delegated
                .map { "\($0.brief) (tâche \($0.taskIds.joined(separator: ", ")))" }
                .joined(separator: " ; ")
        } else if let problem = flow.problem {
            note = problem
        }
        // After an answer the host's cards are the truth: it cleared the delegated ones and kept any that came since.
        await reload(using: model.client, adopting: answered != nil)
    }
}
