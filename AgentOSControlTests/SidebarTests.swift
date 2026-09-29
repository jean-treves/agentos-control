import AppKit
import SwiftUI
import Testing
@testable import AgentOSControl

@Suite struct SidebarTests {
    @Test func sectionsInTheOrderOfSpec16() {
        #expect(SidebarItem.allCases.map(\.title) == ["Aperçu", "Approbations", "Runs", "Tâches", "Mémoire", "Stockage", "Veille emploi"])
        #expect(Set(SidebarItem.allCases.map(\.symbol)).count == SidebarItem.allCases.count)
    }

    /// The rows must be tagged with the SidebarItem itself (`id: \.self`), or the `SidebarItem?`
    /// selection binding never matches them: no row is highlighted and a click sets nil.
    @MainActor @Test func sidebarHighlightsTheCurrentSectionAtLaunch() async {
        let recorder = RequestRecorder()
        let model = ControlModel(
            client: makeClient(recorder: recorder), presence: .deviceOwner, notifier: nil, socket: nil)
        // Borderless, off screen: not a titled window, so it cannot move the Dock icon that
        // AppDelegateTests drive on the same NSApp.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView().environment(model))
        window.orderFront(nil)
        defer {
            window.close()
            window.contentView = nil
        }

        var table: NSTableView?
        for _ in 0..<50 where table?.selectedRow != 0 {
            try? await Task.sleep(for: .milliseconds(100))
            table = firstTable(in: window.contentView)
        }
        #expect(table?.numberOfRows == SidebarItem.allCases.count)
        #expect(table?.selectedRow == 0)
    }

    private func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
    }
}
