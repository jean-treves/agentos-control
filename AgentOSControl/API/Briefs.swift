import Foundation

/// `GET /api/briefs` row (kernel/briefs.py `list_briefs`): a pending brief, draft or validated.
nonisolated struct BriefSummary: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let title: String
    let status: String
    let origin: String
    let project: String
    let outputMode: String
    let agenticMode: String

    var id: String { name }
    var isValidated: Bool { status == "validé" }
}

/// `GET /api/briefs/{name}`: the whole note (header included) and its seal (spec §17.4).
nonisolated struct BriefDetail: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let text: String
    let status: String
    let sha256: String

    var id: String { name }
}

nonisolated struct BriefsEnvelope: Decodable { let briefs: [BriefSummary] }
nonisolated struct BriefValidation: Decodable { let sha256: String }
