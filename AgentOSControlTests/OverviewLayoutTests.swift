import AppKit
import SwiftUI
import Testing
@testable import AgentOSControl

/// Aperçu hosted at the size JT saw it (1100 × 700, borderless, off screen like SidebarTests): the Floor and
/// Health panes must span the window. Before the fix the VSplitView was 70 pt wide, "Joignable" wrapping one
/// letter per line.
@MainActor @Suite struct OverviewLayoutTests {
    private func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { firstSplitView(in: $0) }.first
    }

    @Test func floorAndHealthPanesTakeTheFullWidthAndShareTheHeight() async {
        let recorder = RequestRecorder()
        let model = ControlModel(
            client: makeClient(recorder: recorder), presence: .deviceOwner, notifier: nil, socket: nil)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OverviewView().environment(model))
        window.orderFront(nil)
        defer {
            window.close()
            window.contentView = nil
        }

        var split: NSSplitView?
        for _ in 0..<50 where split?.arrangedSubviews.count != 2 {
            try? await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            split = firstSplitView(in: window.contentView)
        }
        let panes = split?.arrangedSubviews ?? []
        #expect(panes.count == 2)
        for pane in panes {
            #expect(pane.frame.width >= 0.9 * 1100)
            #expect(pane.frame.height >= 150)
        }
    }
}
