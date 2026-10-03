import Foundation
import os

extension String {
    /// Text from outside (a socket, a tool's output) as the screen may show it: control characters, bidi
    /// overrides and Unicode line separators become spaces. The host does the same (`kernel/dialogue.safe`),
    /// but the app does not rely on it: a hostile line must not reorder, hide or split what JT reads.
    /// `keepingLayout` leaves tab and new line, for a body the view lays out.
    nonisolated func plainText(keepingLayout: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            scalars.append(Self.isUnsafe(scalar, keepingLayout: keepingLayout) ? " " : scalar)
        }
        return String(scalars)
    }

    private nonisolated static func isUnsafe(_ scalar: Unicode.Scalar, keepingLayout: Bool) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: !keepingLayout
        case 0x00...0x1F, 0x7F...0xA0: true  // C0, DEL, C1, no-break space
        case 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }
}

/// One line of `runs/<id>/<pane>.jsonl` (kernel/dialogue.py), as `/ws/runs/{id}/dialogue` sends it.
/// Everything in it is untrusted text: it is cleaned on the way in and shown as plain `Text`.
nonisolated struct DialogueLine: Decodable, Sendable, Hashable {
    /// The host cuts a line at 2 000 characters; twice that is already a runaway.
    static let maxTextLength = 4000
    private static let maxRoleLength = 40

    let ts: String
    let role: String
    let text: String

    init(ts: String, role: String, text: String) {
        self.ts = ts.plainText()
        self.role = String(role.plainText().prefix(Self.maxRoleLength))
        let body = text.plainText(keepingLayout: true)
        self.text = body.count > Self.maxTextLength ? String(body.prefix(Self.maxTextLength)) + "…" : body
    }

    private enum CodingKeys: String, CodingKey { case ts, role, text }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ts: try container.decode(String.self, forKey: .ts),
                  role: try container.decode(String.self, forKey: .role),
                  text: try container.decode(String.self, forKey: .text))
    }

    /// `HH:MM:SS` of the ISO timestamp.
    var clock: String { String(ts.dropFirst(11).prefix(8)) }

    /// nil for anything that is not a `{ts, role, text}` record (the host passes such a line through as is).
    static func parse(_ raw: String) -> DialogueLine? {
        try? JSONDecoder().decode(DialogueLine.self, from: Data(raw.utf8))
    }
}

nonisolated enum DialoguePane: String, CaseIterable, Sendable {
    case claude, hermes
    var title: String { self == .claude ? "Claude" : "Hermès" }
}

nonisolated enum DialogueEvent: Equatable, Sendable {
    case connected  // the host resends its backlog: the view starts again
    case line(DialogueLine)
}

/// The last 2 000 lines of one pane.
nonisolated struct DialogueBuffer: Equatable, Sendable {
    static let limit = 2000

    /// A line with a number that never changes: the list keeps its rows when older ones fall off.
    nonisolated struct Numbered: Identifiable, Equatable, Sendable {
        let id: Int
        let line: DialogueLine
    }

    private(set) var lines: [DialogueLine] = []
    /// Lines that fell off the top since the last reset.
    private var dropped = 0

    var numbered: [Numbered] { lines.enumerated().map { Numbered(id: dropped + $0.offset, line: $0.element) } }

    mutating func apply(_ event: DialogueEvent) {
        switch event {
        case .connected:
            lines.removeAll()
            dropped = 0
        case .line(let line):
            lines.append(line)
            if lines.count > Self.limit {
                let extra = lines.count - Self.limit
                lines.removeFirst(extra)
                dropped += extra
            }
        }
    }
}

/// Read-only listener on `/ws/runs/{id}/dialogue?pane=…` (spec §17.7); reconnects every 2 s.
///
/// No `Origin` header: a `URLSessionWebSocketTask` sends none, and the host only refuses a foreign one
/// (`server/auth.foreign_origin`). Nothing is ever sent to the host: steering goes through Approbations.
nonisolated final class DialogueSocket: Sendable {
    let url: URL
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "dialogue")

    init(baseURL: URL, runID: String, pane: DialoguePane) {
        url = Self.socketURL(for: baseURL, runID: runID, pane: pane)
    }

    static func socketURL(for baseURL: URL, runID: String, pane: DialoguePane) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/runs/\(runID)/dialogue"
        components.queryItems = [URLQueryItem(name: "pane", value: pane.rawValue)]
        return components.url!
    }

    func events() -> AsyncStream<DialogueEvent> {
        AsyncStream { continuation in
            let loop = Task {
                while !Task.isCancelled {
                    await receiveUntilClosed(continuation)
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in loop.cancel() }
        }
    }

    /// `.connected` goes out with the first line of a connection, not at its opening: while the host is
    /// down the pane keeps what it showed, and an answered connection starts again from the backlog.
    private func receiveUntilClosed(_ continuation: AsyncStream<DialogueEvent>.Continuation) async {
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        await withTaskCancellationHandler {
            var answered = false
            do {
                while true {
                    guard case .string(let text) = try await socket.receive(), let line = DialogueLine.parse(text)
                    else { continue }
                    if !answered {
                        answered = true
                        continuation.yield(.connected)
                    }
                    continuation.yield(.line(line))
                }
            } catch {
                logger.info("dialogue closed: \(error.localizedDescription, privacy: .public)")
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}

/// Whether a pane follows its end. Moving up stops it; coming back to the end resumes it.
/// What counts is the movement of the visible bottom edge: a line arriving makes the content grow before
/// the view has followed it (the end looks far for a moment), and the first reading of a pane that has
/// not scrolled yet is not a gesture either.
nonisolated struct ScrollFollow: Equatable, Sendable {
    /// What a pane needs of its scroll view.
    nonisolated struct Metrics: Equatable, Sendable {
        let bottomEdge: Double  // lowest visible point, in content coordinates
        let viewport: Double
        let content: Double
    }

    /// Points from the end still counted as « at the end ».
    static let slack = 12.0

    private(set) var isFollowing = true

    mutating func scrolled(from old: Metrics, to new: Metrics) {
        // A resize moves the edge without anyone scrolling: the state stays.
        guard new.viewport == old.viewport, new.bottomEdge != old.bottomEdge else { return }
        let atEnd = new.content - new.bottomEdge <= Self.slack
        if new.bottomEdge < old.bottomEdge {
            isFollowing = atEnd
        } else if atEnd {
            isFollowing = true  // moving down never pauses: the view itself follows by moving down
        }
    }
}
