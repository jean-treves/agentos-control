import Foundation

/// `GET /api/conversations` (kernel/conversations.py, spec §17.13): the list, the choices the view
/// needs (projects, modes, card fields) and the last known 5-hour quota.
nonisolated struct ConversationIndex: Decodable, Sendable, Hashable {
    let conversations: [ConversationSummary]
    let options: ConversationOptions
    let quota: QuotaInfo
}

nonisolated struct ConversationSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let project: String
    let mode: String
    let turns: Int
    let busy: Bool
}

/// Value → label maps: the keys are sent back to the host as they are.
nonisolated struct ConversationOptions: Decodable, Sendable, Hashable {
    static let modeOrder = ["read", "modify"]

    let projects: [String]
    let modes: [String: String]
    let outputModes: [String: String]
    let agenticModes: [String: String]
    let executorModels: [String]
    let efforts: [String]
}

/// The 5-hour window of the last Claude run that reported one (decision D35).
/// `state`: `ok`, `warn` (above 85 %) or `exhausted` (nothing is sent). The host decides the state; the
/// utilization is a fraction (0.86 = 86 %) and `fiveHourResetsAt` an epoch in seconds.
nonisolated struct QuotaInfo: Decodable, Sendable, Hashable {
    let fiveHourUtilization: Double?
    let fiveHourResetsAt: Double?
    let state: String

    var line: String {
        guard let used = fiveHourUtilization else { return "quota 5 h inconnu" }
        let percent = Int((used * 100).rounded())
        switch state {
        case "exhausted": return "quota 5 h épuisé (\(percent) %) : rien n'est envoyé"
        case "warn": return "quota 5 h à \(percent) % : chaque message le consomme"
        default: return "quota 5 h : \(percent) %"
        }
    }

    /// When the window reopens, in `timeZone`; nil when unknown or already past.
    func resetNote(now: Date = Date(), in timeZone: TimeZone = .current) -> String? {
        guard let epoch = fiveHourResetsAt else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        guard date > now else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "remise à zéro à %02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}

/// `GET /api/conversations/{id}`: the host's state file plus `busy` and `quota`.
nonisolated struct ConversationDetail: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let project: String
    let mode: String
    let turns: Int
    let busy: Bool
    let worktree: String?
    let quota: QuotaInfo
    let cards: [DelegationCard]
    let cardsError: String?
    /// +1 each time a reply brings new cards (`Conversation.cards_seq`): « Déléguer » sends the number of the cards
    /// JT read, so the host clears those and keeps any that arrived since. nil from a host that sends none.
    let cardsSeq: Int?
}

/// One task Sonnet proposes (the `agentos-delegation` block); JT edits it before « Déléguer ».
/// Exactly the ten fields of `kernel/delegation.FIELDS`: the host refuses a card with another key.
nonisolated struct DelegationCard: Codable, Sendable, Hashable {
    var title: String
    var project: String
    var goal: String
    var context: String
    var doneWhen: String
    var verify: String
    var outputMode: String
    var agenticMode: String
    var executorModel: String
    var sonnetEffort: String

    fileprivate enum CodingKeys: String, CodingKey {
        case title, project, goal, context, doneWhen, verify, outputMode, agenticMode, executorModel, sonnetEffort
    }
}

extension DelegationCard {
    /// A card is text a model wrote, cleaned by the host and cleaned again here: what the editor shows and
    /// sends back holds no control or bidi character. `context`, `verify` and `sonnetEffort` have the host's
    /// defaults (`DEFAULTS`) when absent.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, keepingLayout: Bool = false) throws -> String {
            try container.decode(String.self, forKey: key).plainText(keepingLayout: keepingLayout)
        }
        func optional(_ key: CodingKeys, _ fallback: String, keepingLayout: Bool = false) throws -> String {
            try container.decodeIfPresent(String.self, forKey: key)?.plainText(keepingLayout: keepingLayout) ?? fallback
        }
        self.init(title: try text(.title), project: try text(.project), goal: try text(.goal, keepingLayout: true),
                  context: try optional(.context, "", keepingLayout: true),
                  doneWhen: try text(.doneWhen, keepingLayout: true), verify: try optional(.verify, ""),
                  outputMode: try text(.outputMode), agenticMode: try text(.agenticMode),
                  executorModel: try text(.executorModel), sonnetEffort: try optional(.sonnetEffort, "medium"))
    }
}

nonisolated struct DelegatedBrief: Decodable, Sendable, Hashable {
    let brief: String
    let sha256: String
    let taskIds: [String]
    let runIds: [String]
}

nonisolated struct DelegationReply: Decodable, Sendable, Hashable { let delegated: [DelegatedBrief] }
nonisolated struct TurnStarted: Decodable, Sendable, Hashable { let id: String; let turnId: String }
nonisolated struct PromotionReply: Decodable, Sendable, Hashable { let branch: String; let head: String }
