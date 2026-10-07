import AppKit
import SwiftUI
import Testing
@testable import AgentOSControl

@Suite struct SidebarTests {
    @Test func sectionsInTheOrderOfSpec16() {
        #expect(SidebarItem.allCases.map(\.title) == ["Aperçu", "Conversation", "Commandes", "Approbations", "Runs", "Tâches", "Mémoire", "Stockage", "Veille emploi", "Wiki"])
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

    /// A click on an approval's notification switches to Approbations, except while a sheet is open: leaving the
    /// section removes the view that presents it, and the sheet with what JT typed (a Drawback prompt, a
    /// delegation review, Ménage). The request stays pending until he opens the section himself.
    @MainActor @Test func aRevealSwitchesSectionUnlessASheetIsOpen() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        #expect(MainView.shouldSwitchSection(revealed: "a1", windows: []))
        #expect(MainView.shouldSwitchSection(revealed: "a1", windows: [window(), window()]))
        #expect(!MainView.shouldSwitchSection(revealed: "a1", windows: [window(), SheetedWindow(), window()]))
        #expect(!MainView.shouldSwitchSection(revealed: nil, windows: []))  // nothing was asked for
    }

    private func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
    }
}

/// A window that reports a sheet attached, without running AppKit's modal machinery in the test host.
private final class SheetedWindow: NSWindow {
    private let attached = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    override var attachedSheet: NSWindow? { attached }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        attached.isReleasedWhenClosed = false
    }
}
