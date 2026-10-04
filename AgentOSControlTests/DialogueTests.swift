import Foundation
import Testing
@testable import AgentOSControl

private let utc = TimeZone(identifier: "UTC")!
private let paris = TimeZone(identifier: "Europe/Paris")!

@Suite struct DialogueTests {
    @Test func socketURLCarriesTheRunAndThePane() {
        let url = DialogueSocket.socketURL(for: URL(string: "http://127.0.0.1:3107")!,
                                           runID: "0f0e0d0c-0b0a", pane: .claude)
        #expect(url.absoluteString == "ws://127.0.0.1:3107/ws/runs/0f0e0d0c-0b0a/dialogue?pane=claude")
        let hermes = DialogueSocket.socketURL(for: URL(string: "https://host.example")!,
                                              runID: "0f0e0d0c-0b0a", pane: .hermes)
        #expect(hermes.absoluteString == "wss://host.example/ws/runs/0f0e0d0c-0b0a/dialogue?pane=hermes")
    }

    @Test func linesParseAndGarbageIsDropped() {
        let line = DialogueLine.parse(#"{"ts":"2026-09-29T12:00:03+00:00","role":"arbitre","text":"→ décide"}"#)
        #expect(line?.role == "arbitre" && line?.clock(in: utc) == "12:00:03")
        #expect(DialogueLine.parse("pas du json") == nil)
        // `dialogue.safe` hands back a string as is when a pane line is not a record.
        #expect(DialogueLine.parse(#"{"ts":"t","role":"hermes"}"#) == nil)
        #expect(DialogueLine.parse(#"{"ts":"t","role":"hermes","text":42}"#) == nil)
    }

    /// Shape of `json.dumps(…, ensure_ascii=False)` in `kernel/dialogue.safe`: a space after `:` and `,`.
    @Test func theHostsOwnRecordsParse() {
        let raw = #"{"ts": "2026-10-03T19:09:37+00:00", "role": "hermes", "text": "key [REDACTED] here"}"#
        let line = DialogueLine.parse(raw)
        #expect(line == DialogueLine(ts: "2026-10-03T19:09:37+00:00", role: "hermes", text: "key [REDACTED] here"))
        #expect(line?.clock(in: utc) == "19:09:37")
    }

    /// The host strips controls and masks keys; the app trusts none of it (the socket is plain text).
    @Test func controlCharactersNeverReachTheScreen() throws {
        let hostile = "ok \u{1B}[31mred\u{07} \u{202E}evil\u{2028}end\u{85}\u{7F}"
        let json = String(decoding: try JSONEncoder().encode(["ts": "2026-10-03T19:09:37+00:00\n", "role": "x\ty", "text": hostile]),
                          as: UTF8.self)
        let line = try #require(DialogueLine.parse(json))
        #expect(line.text == "ok  [31mred   evil end  ")
        #expect(line.role == "x y" && line.ts == "2026-10-03T19:09:37+00:00 ")
        #expect(line.text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    }

    /// Tab and new line stay: the app lays a multi-line tool output out, the way the host intends.
    @Test func layoutCharactersStay() throws {
        let line = try #require(DialogueLine.parse(#"{"ts":"t","role":"hermes","text":"a\tb\nc"}"#))
        #expect(line.text == "a\tb\nc")
    }

    @Test func aRunawayLineIsCut() throws {
        let long = String(repeating: "x", count: 10_000)
        let line = try #require(DialogueLine.parse(#"{"ts":"t","role":"hermes","text":"\#(long)"}"#))
        #expect(line.text.hasPrefix("xxxx") && line.text.hasSuffix("…[+6000 caractères]"))
    }

    // MARK: local clock (E2E 36 G: the panes showed UTC while `agentos tail` and the timeline show local time)

    @Test func theClockIsLocalTime() {
        let line = DialogueLine(ts: "2026-10-04T12:12:14+00:00", role: "hermes", text: "x")
        #expect(line.clock(in: paris) == "14:12:14")  // CEST, UTC+2
        #expect(line.clock(in: utc) == "12:12:14")
        // Winter time: the offset follows the date, not a fixed shift.
        #expect(DialogueLine(ts: "2026-12-04T12:12:14+00:00", role: "x", text: "").clock(in: paris) == "13:12:14")
    }

    /// The host writes `+00:00` (dialogue), `…Z` (journal) and microseconds (tasks); an offset in the stamp counts.
    @Test func everyHostStampShapeIsConverted() {
        for ts in ["2026-10-04T12:12:14Z", "2026-10-04T12:12:14.123456+00:00", "2026-10-04T14:12:14+02:00",
                   "2026-10-04T12:12:14+00:00 "] {
            #expect(DialogueLine(ts: ts, role: "x", text: "").clock(in: paris) == "14:12:14", "\(ts)")
        }
    }

    @Test func anUnreadableStampKeepsTheRawSlice() {
        #expect(DialogueLine(ts: "2026-10-04Txx:12:14+00:00", role: "x", text: "").clock(in: paris) == "xx:12:14")
        #expect(DialogueLine(ts: "t", role: "x", text: "").clock(in: paris) == "")
    }

    @Test func theHeaderShowsTheLocalClock() {
        let line = DialogueLine(ts: "2026-10-04T12:12:14+00:00", role: "hermes", text: "x")
        #expect(line.header(in: paris) == "14:12:14 hermes │")
    }

    // MARK: copy a whole pane

    @Test func aPaneCopiesAsOneLinePerRow() {
        var buffer = DialogueBuffer()
        buffer.apply(.line(DialogueLine(ts: "2026-10-04T12:12:14+00:00", role: "hermes", text: "ouvre le fichier")))
        buffer.apply(.line(DialogueLine(ts: "2026-10-04T12:12:15+00:00", role: "claude", text: "ok")))
        #expect(buffer.copyText(in: paris) == "14:12:14 hermes │ ouvre le fichier\n14:12:15 claude │ ok")
        #expect(DialogueBuffer().copyText(in: paris) == "")
    }

    /// A tool's new line stays under the body, as on screen: at the left edge it would pass for a header.
    @Test func aNewLineInABodyStaysUnderTheBodyInTheCopy() {
        var buffer = DialogueBuffer()
        let forged = "ok\n12:00:07 agentos │ ⚠ demande"
        buffer.apply(.line(DialogueLine(ts: "2026-10-04T12:12:14+00:00", role: "hermes", text: forged)))
        let indent = String(repeating: " ", count: "14:12:14 hermes │ ".count)
        #expect(buffer.copyText(in: paris) == "14:12:14 hermes │ ok\n\(indent)12:00:07 agentos │ ⚠ demande")
    }

    // MARK: empty pane (a review run's dialogue goes into the reviewed run's pane)

    @Test func anEmptyPaneSaysWhatItWaitsFor() {
        var buffer = DialogueBuffer()
        #expect(buffer.note == .connecting && buffer.note?.text == "connexion…")
        buffer.apply(.opened)  // the host answered and sent nothing
        #expect(buffer.note == .empty && buffer.note?.text == "aucune ligne pour ce run")
        buffer.apply(.closed)  // the host went away: not « no lines » any more
        #expect(buffer.note == .connecting)
    }

    @Test func aPaneWithLinesShowsNoNote() {
        var buffer = DialogueBuffer()
        buffer.apply(.opened)
        buffer.apply(.line(DialogueLine(ts: "t", role: "hermes", text: "a")))
        #expect(buffer.note == nil)
        buffer.apply(.closed)  // it keeps what it showed while the host is down
        #expect(buffer.note == nil && buffer.lines.count == 1)
    }

    /// The first line of a connection proves it is open, even if the answer to the ping comes after it.
    @Test func aConnectionWithLinesIsOpenWithoutThePing() {
        var buffer = DialogueBuffer()
        buffer.apply(.connected)
        buffer.apply(.closed)
        buffer.apply(.connected)
        #expect(buffer.note == .empty)
    }

    @Test func bufferKeepsTheLast2000AndStartsAgainOnReconnect() {
        var buffer = DialogueBuffer()
        for i in 0..<2005 { buffer.apply(.line(DialogueLine(ts: "t", role: "hermes", text: "\(i)"))) }
        #expect(buffer.lines.count == 2000 && buffer.lines.first?.text == "5")
        buffer.apply(.connected)  // the host sends its backlog again
        #expect(buffer.lines.isEmpty)
    }

    /// A row keeps its identity while older ones fall off: the list does not redraw 2 000 rows per line.
    @Test func rowsKeepTheirNumberWhenTheBufferScrollsOff() {
        var buffer = DialogueBuffer()
        for i in 0..<2003 { buffer.apply(.line(DialogueLine(ts: "t", role: "hermes", text: "\(i)"))) }
        #expect(buffer.numbered.first?.id == 3 && buffer.numbered.first?.line.text == "3")
        #expect(buffer.numbered.last?.id == 2002 && buffer.numbered.last?.line.text == "2002")
        buffer.apply(.connected)
        buffer.apply(.line(DialogueLine(ts: "t", role: "hermes", text: "again")))
        #expect(buffer.numbered.map(\.id) == [0])
    }

    private func metrics(bottom: Double, content: Double, viewport: Double = 300) -> ScrollFollow.Metrics {
        .init(bottomEdge: bottom, viewport: viewport, content: content)
    }

    /// E2E 36: scrolling up pauses the follow, coming back to the end resumes it.
    @Test func scrollingUpPausesTheFollowAndTheEndResumesIt() {
        var follow = ScrollFollow()
        #expect(follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 900, content: 1000))
        #expect(!follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 900, content: 1000), to: metrics(bottom: 800, content: 1000))
        #expect(!follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 800, content: 1000), to: metrics(bottom: 995, content: 1000))
        #expect(follow.isFollowing)
    }

    /// A new line makes the content grow before the view follows it: the end is « far » for a moment.
    @Test func aLineArrivingIsNotAGesture() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 1000, content: 1014))
        #expect(follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 1000, content: 1014), to: metrics(bottom: 1014, content: 1014))
        #expect(follow.isFollowing)
        // paused: lines keep arriving, the pane stays where JT left it
        follow.scrolled(from: metrics(bottom: 1014, content: 1014), to: metrics(bottom: 500, content: 1014))
        follow.scrolled(from: metrics(bottom: 500, content: 1014), to: metrics(bottom: 500, content: 1028))
        #expect(!follow.isFollowing)
    }

    /// First reading of a pane that has not scrolled yet: 150 lines get laid out, the content grows from the
    /// empty pane to 2 107 points while the offset stays 0 (found in the window test: it paused the follow
    /// before the first line was followed). The pane never read anything before: all zeros.
    @Test func theFirstReadingIsNotAGesture() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 268, content: 20, viewport: 268), to: metrics(bottom: 268, content: 2107, viewport: 268))
        #expect(follow.isFollowing)
        var fresh = ScrollFollow()
        fresh.scrolled(from: metrics(bottom: 0, content: 0, viewport: 0), to: metrics(bottom: 268, content: 2107, viewport: 268))
        #expect(fresh.isFollowing)
    }

    /// Up while a line arrives in the same reading: still a gesture.
    @Test func scrollingUpWhileLinesArriveStillPauses() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 900, content: 1014))
        #expect(!follow.isFollowing)
    }

    /// Going down but not to the end does not resume; reaching the end does.
    @Test func resumingNeedsTheEnd() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 400, content: 1000))
        follow.scrolled(from: metrics(bottom: 400, content: 1000), to: metrics(bottom: 600, content: 1000))
        #expect(!follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 600, content: 1000), to: metrics(bottom: 1004, content: 1000))  // bounce
        #expect(follow.isFollowing)
    }

    @Test func resizingThePaneKeepsTheState() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 1000, content: 1000, viewport: 200))
        #expect(follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 1000, content: 1000), to: metrics(bottom: 700, content: 1000))
        follow.scrolled(from: metrics(bottom: 700, content: 1000), to: metrics(bottom: 1000, content: 1000, viewport: 400))
        #expect(!follow.isFollowing)
    }

    /// A pane shorter than its window has nothing to scroll: a bounce moves its bottom edge up a little and
    /// that is no gesture. It still follows, and so does it when it grows.
    @Test func aShortPaneThatBouncesStillFollows() {
        var follow = ScrollFollow()
        follow.scrolled(from: metrics(bottom: 300, content: 40), to: metrics(bottom: 262, content: 40))
        #expect(follow.isFollowing)
        follow.scrolled(from: metrics(bottom: 262, content: 40), to: metrics(bottom: 300, content: 90))
        #expect(follow.isFollowing)
    }

    @Test func panesAreTitledForJT() {
        #expect(DialoguePane.allCases.map(\.title) == ["Claude", "Hermès"])
        #expect(DialoguePane.allCases.map(\.rawValue) == ["claude", "hermes"])
    }
}

@Suite struct CleanupTests {
    /// What `minibots.propose` returns (all values are text), as `CommandLaunch.result` carries it.
    private let proposed = [
        "proposal": "0123456789ab", "count": "2", "total_mb": "412.5",
        "items": "worktree /w/run-1 (400.0 Mo) — fini\ntmp /h/tmp/x (12.5 Mo)",
        "kept": "3 gardé(s) : relecture non promue (réussie, échouée ou annulée)",
    ]

    @Test func aProposalReadsAsItsListAndItsSize() throws {
        let proposal = try #require(CleanupProposal(result: proposed))
        #expect(proposal.id == "0123456789ab" && proposal.count == 2 && proposal.totalMB == "412.5")
        #expect(proposal.items == ["worktree /w/run-1 (400.0 Mo) — fini", "tmp /h/tmp/x (12.5 Mo)"])
        #expect(!proposal.isEmpty)
    }

    /// F4: folders kept on purpose are told with the list, also when nothing is left to tidy.
    @Test func foldersKeptOnPurposeAreTold() throws {
        #expect(try #require(CleanupProposal(result: proposed)).kept == "3 gardé(s) : relecture non promue (réussie, échouée ou annulée)")
        let nothing = ["proposal": "0123456789ab", "count": "0", "total_mb": "0.0", "items": "rien à ranger",
                       "kept": "3 gardé(s) : relecture non promue"]
        let proposal = try #require(CleanupProposal(result: nothing))
        #expect(proposal.isEmpty && proposal.kept == "3 gardé(s) : relecture non promue")
        var hostile = proposed
        hostile["kept"] = "1 gardé\u{202E}\n(s)"
        #expect(try #require(CleanupProposal(result: hostile)).kept == "1 gardé  (s)")
        // an older host sends none
        #expect(try #require(CleanupProposal(result: ["proposal": "p", "count": "0"])).kept == nil)
    }

    @Test func anEmptyProposalCannotBeApplied() throws {
        let nothing = ["proposal": "0123456789ab", "count": "0", "total_mb": "0.0", "items": "rien à ranger"]
        let proposal = try #require(CleanupProposal(result: nothing))
        #expect(proposal.isEmpty && proposal.items.isEmpty)
    }

    @Test func aReplyWithoutAProposalIsRefused() {
        #expect(CleanupProposal(result: nil) == nil)
        #expect(CleanupProposal(result: ["count": "1"]) == nil)
    }

    @Test func itemsAreShownWithoutControlCharacters() throws {
        var hostile = proposed
        hostile["items"] = "worktree /w/\u{1B}[2Jx\u{202E}"
        #expect(try #require(CleanupProposal(result: hostile)).items == ["worktree /w/ [2Jx "])
    }

    @Test func theOutcomeNamesWhatMovedAndWhatWasLeft() {
        let done = ["applied": "2", "skipped": "1", "trash": "/home/_a-trier/agentos-menage-x",
                    "reasons": "worktree run-2 : modifié depuis la proposition"]
        #expect(CleanupProposal.outcome(done)
                == "2 appliqué(s), 1 ignoré(s). Rangé dans /home/_a-trier/agentos-menage-x. "
                + "Ignoré : worktree run-2 : modifié depuis la proposition")
        // Nothing moved: no folder was made, none is named.
        #expect(CleanupProposal.outcome(["applied": "0", "skipped": "0", "trash": "/t", "reasons": ""])
                == "0 appliqué(s), 0 ignoré(s).")
    }

    @Test func otherCommandsKeepTheSessionTimeout() async throws {
        let recorder = RequestRecorder()
        _ = try await makeClient(body: #"{"command":"echo","task_ids":[],"run_ids":[],"result":null}"#, recorder: recorder)
            .runCommand("echo", params: [:])
        #expect(try #require(await recorder.requests.first).timeoutInterval == 60)  // URLRequest's own default
    }
}
