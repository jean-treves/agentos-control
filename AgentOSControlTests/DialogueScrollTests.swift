import AppKit
import Observation
import SwiftUI
import Testing
@testable import AgentOSControl

@Observable private final class BufferBox {
    var buffer = DialogueBuffer()

    func append(_ count: Int, from start: Int = 0) {
        for i in start..<(start + count) {
            buffer.apply(.line(DialogueLine(ts: "2026-10-03T12:00:00+00:00", role: "hermes", text: "line \(i)")))
        }
    }
}

private struct Harness: View {
    let box: BufferBox
    var body: some View { DialogueTerminal(title: "Hermès", buffer: box.buffer) }
}

/// The real SwiftUI terminal in a window, its NSScrollView moved the way a trackpad moves it: the follow
/// logic is unit-tested apart (`ScrollFollow`), this checks that the view really wires it up (E2E 36).
@Suite(.serialized) struct DialogueScrollTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    /// Points between the last visible line and the end of the content.
    private func distanceFromEnd(_ scroll: NSScrollView) -> Double {
        let content = scroll.documentView?.frame.height ?? 0
        return content - scroll.contentView.bounds.maxY
    }

    private func state(_ scroll: NSScrollView) -> String {
        "doc \(scroll.documentView?.frame.height ?? -1) clip \(scroll.contentView.bounds)"
    }

    private func scroll(_ scroll: NSScrollView, toY y: Double) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @Test func followsTheEndUntilJTScrollsUpThenResumesAtTheBottom() async throws {
        let box = BufferBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0  // laid out and drawn, never seen
        window.contentView = NSHostingView(rootView: Harness(box: box))
        window.orderFront(nil)
        defer { window.close() }

        box.append(150)
        try await settle()
        let root = try #require(window.contentView)
        let pane = try #require(scrollView(in: root))
        #expect((pane.documentView?.frame.height ?? 0) > 600, "the 150 lines are laid out")
        #expect(distanceFromEnd(pane) < 8, "a pane that was never touched follows its end \(state(pane))")

        box.append(30, from: 150)
        try await settle()
        #expect(distanceFromEnd(pane) < 8, "new lines are followed \(state(pane))")

        scroll(pane, toY: 0)  // JT scrolls up to the first line
        try await settle()
        box.append(30, from: 180)
        try await settle()
        #expect(pane.contentView.bounds.minY < 2, "scrolled up: lines arrive, the pane stays put")
        #expect(distanceFromEnd(pane) > 300)

        scroll(pane, toY: (pane.documentView?.frame.height ?? 0) - pane.contentView.bounds.height)  // back to the end
        try await settle()
        box.append(30, from: 210)
        try await settle()
        #expect(distanceFromEnd(pane) < 8, "back at the end: the follow resumes \(state(pane))")
    }

    /// At the 2 000-line limit the count stops moving while lines keep coming: the follow must not.
    @Test func keepsFollowingAtTheLimit() async throws {
        let box = BufferBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: Harness(box: box))
        window.orderFront(nil)
        defer { window.close() }

        box.append(1990)
        try await settle()
        box.append(40, from: 1990)
        try await settle()
        #expect(box.buffer.lines.count == DialogueBuffer.limit && box.buffer.numbered.last?.id == 2029)
        let root = try #require(window.contentView)
        let pane = try #require(scrollView(in: root))
        #expect(distanceFromEnd(pane) < 8, "followed past the limit \(state(pane))")
    }

    /// Lines arriving one by one, as the socket delivers them: JT scrolls up in the middle of the stream.
    @Test func staysWhereJTLeftItWhileLinesStream() async throws {
        let box = BufferBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: Harness(box: box))
        window.orderFront(nil)
        defer { window.close() }

        for i in 0..<60 {
            box.append(1, from: i)
            try await Task.sleep(for: .milliseconds(15))
        }
        try await settle()
        let root = try #require(window.contentView)
        let pane = try #require(scrollView(in: root))
        #expect(distanceFromEnd(pane) < 8, "streamed lines are followed \(state(pane))")

        scroll(pane, toY: 200)  // JT scrolls up while the stream goes on
        for i in 60..<120 {
            box.append(1, from: i)
            try await Task.sleep(for: .milliseconds(15))
        }
        try await settle()
        #expect(abs(pane.contentView.bounds.minY - 200) < 2, "paused: the pane did not move \(state(pane))")
    }
}
