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

extension String {
    /// `kernel/dialogue.clean` without its secret masking (the host masks before it seals): control, bidi,
    /// separator and invisible characters become one space per run (any other format character, one each), then
    /// the text is trimmed; a one-line text also folds every whitespace run into a single space. A card JT edits
    /// is shown with exactly this, so the review is the sealed brief.
    nonisolated func hostCleaned(oneLine: Bool) -> String {
        var spaced = String.UnicodeScalarView()
        var inRun = false
        for scalar in unicodeScalars {
            if Self.isInvisibleOrControl(scalar) {
                if !inRun { spaced.append(" ") }
                inRun = true
            } else {
                inRun = false
                spaced.append(scalar.properties.generalCategory == .format ? " " : scalar)
            }
        }
        let isSpace: (Unicode.Scalar) -> Bool = { $0.properties.isWhitespace }
        if oneLine {
            return spaced.split(whereSeparator: isSpace).map { String(String.UnicodeScalarView($0)) }
                .joined(separator: " ")
        }
        guard let start = spaced.firstIndex(where: { !isSpace($0) }),
              let end = spaced.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(spaced[start...end])
    }

    /// `dialogue._STRICT`: C0 (not tab and new line), DEL, C1, no-break space, bidi marks and overrides, zero-width
    /// characters, line and paragraph separators, invisible operators, variation selectors, BOM, tag characters.
    private nonisolated static func isInvisibleOrControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B...0x1F, 0x7F...0xA0, 0x061C, 0x200B...0x200F, 0x2028, 0x2029, 0x202A...0x202E,
             0x2060...0x2064, 0x2066...0x2069, 0xFE00...0xFE0F, 0xFEFF, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            true
        default: false
        }
    }
}

/// One line of `runs/<id>/<pane>.jsonl` (kernel/dialogue.py), as `/ws/runs/{id}/dialogue` sends it.
/// Everything in it is untrusted text: it is cleaned on the way in and shown as plain `Text`.
nonisolated struct DialogueLine: Decodable, Sendable, Hashable {
    /// The host cuts a line at 2 000 characters; twice that is already a runaway.
    static let maxTextLength = 4000
    /// A conversation's reply is one line of up to 100 000 characters (`conversations.MAX_LINE_CHARS`) and
    /// the transcript shows it whole, with the `…[+N caractères]` the host adds after a cut (`dialogue.write`): room
    /// for it, or the app would cut off the one thing that says how much is missing.
    static let transcriptTextLength = 100_000 + 64
    private static let maxRoleLength = 40

    let ts: String
    let role: String
    let text: String

    init(ts: String, role: String, text: String, maxTextLength: Int = DialogueLine.maxTextLength) {
        self.ts = ts.plainText()
        self.role = String(role.plainText().prefix(Self.maxRoleLength))
        let body = text.plainText(keepingLayout: true)
        // The reader is told how much is missing, as the host's own cut does.
        self.text = body.count > maxTextLength
            ? String(body.prefix(maxTextLength)) + "…[+\(body.count - maxTextLength) caractères]" : body
    }

    private enum CodingKeys: String, CodingKey { case ts, role, text }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ts: try container.decode(String.self, forKey: .ts),
                  role: try container.decode(String.self, forKey: .role),
                  text: try container.decode(String.self, forKey: .text))
    }

    /// `HH:mm:ss` of the ISO timestamp in `timeZone` (default: this Mac's), as `agentos tail` and the run
    /// timeline show it: the host stamps UTC. A stamp that does not parse keeps its raw `HH:MM:SS` slice.
    func clock(in timeZone: TimeZone = .current) -> String {
        guard let date = parseTimestamp(ts.trimmingCharacters(in: .whitespaces)) else {
            return String(ts.dropFirst(11).prefix(8))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", time.hour ?? 0, time.minute ?? 0, time.second ?? 0)
    }

    func header(in timeZone: TimeZone = .current) -> String { "\(clock(in: timeZone)) \(role) │" }

    /// nil for anything that is not a `{ts, role, text}` record (the host passes such a line through as is).
    static func parse(_ raw: String, maxTextLength: Int = DialogueLine.maxTextLength) -> DialogueLine? {
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(raw.utf8)) else { return nil }
        return DialogueLine(ts: record.ts, role: record.role, text: record.text, maxTextLength: maxTextLength)
    }

    private struct Record: Decodable {
        let ts: String
        let role: String
        let text: String
    }
}

nonisolated enum DialoguePane: String, CaseIterable, Sendable {
    case claude, hermes
    var title: String { self == .claude ? "Claude" : "Hermès" }
}

nonisolated enum DialogueEvent: Equatable, Sendable {
    case connected  // the host resends its backlog: the view starts again
    case opened  // the host answered a ping: the connection is open, lines or not
    case closed
    case line(DialogueLine)
}

/// What an empty pane says in place of lines.
nonisolated enum PaneNote: Equatable, Sendable {
    case connecting, empty

    var text: String { self == .connecting ? "connexion…" : "aucune ligne pour ce run" }
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
    /// A connection to the host is open now. A pane keeps its lines while the host is down, this flag does not.
    private(set) var isOpen = false

    /// Why an empty pane is empty: still connecting (or the host is down), or connected and nothing was written
    /// (a review run's dialogue goes into the reviewed run's pane). nil once there are lines to show.
    var note: PaneNote? { lines.isEmpty ? (isOpen ? .empty : .connecting) : nil }

    var numbered: [Numbered] { lines.enumerated().map { Numbered(id: dropped + $0.offset, line: $0.element) } }

    mutating func apply(_ event: DialogueEvent) {
        switch event {
        case .connected:
            lines.removeAll()
            dropped = 0
            isOpen = true
        case .opened: isOpen = true
        case .closed: isOpen = false
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

extension DialogueBuffer {
    /// The whole pane as plain text for the pasteboard, one line per row: `clock role │ text`. A new line
    /// inside a body stays under the body, as on screen: at the left edge it would pass for a header.
    func copyText(in timeZone: TimeZone = .current) -> String {
        lines.map { line in
            let header = line.header(in: timeZone)
            let continuation = "\n" + String(repeating: " ", count: header.count + 1)
            return header + " " + line.text.replacingOccurrences(of: "\n", with: continuation)
        }.joined(separator: "\n")
    }
}

/// Read-only listener on `/ws/runs/{id}/dialogue?pane=…` (spec §17.7); reconnects every 2 s.
///
/// No `Origin` header: a `URLSessionWebSocketTask` sends none, and the host only refuses a foreign one
/// (`server/auth.foreign_origin`). No data is ever sent to the host (only a ping, a control frame that carries
/// none): steering goes through Approbations.
nonisolated final class DialogueSocket: Sendable {
    let url: URL
    let maxTextLength: Int
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "dialogue")

    init(baseURL: URL, runID: String, pane: DialoguePane) {
        url = Self.socketURL(for: baseURL, runID: runID, pane: pane)
        maxTextLength = DialogueLine.maxTextLength
    }

    init(url: URL, maxTextLength: Int = DialogueLine.maxTextLength) {
        self.url = url
        self.maxTextLength = maxTextLength
    }

    /// The listener of a conversation's transcript: lines of up to `DialogueLine.transcriptTextLength`.
    static func transcript(for baseURL: URL, id: String) -> DialogueSocket {
        DialogueSocket(url: conversationURL(for: baseURL, id: id), maxTextLength: DialogueLine.transcriptTextLength)
    }

    /// `/ws/conversations/{id}` (T8.5c): a conversation's transcript, the same lines as a run's pane.
    static func conversationURL(for baseURL: URL, id: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/conversations/\(id)"
        return components.url!
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
        // A pane with no line sends nothing, so waiting for a line cannot tell « connected, nothing yet »
        // from « host down »: the pong says the connection is open.
        socket.sendPing { error in if error == nil { continuation.yield(.opened) } }
        await withTaskCancellationHandler {
            var answered = false
            do {
                while true {
                    guard case .string(let text) = try await socket.receive(),
                          let line = DialogueLine.parse(text, maxTextLength: maxTextLength)
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
            continuation.yield(.closed)
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
