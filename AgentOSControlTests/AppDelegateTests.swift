import AppKit
import Testing
@testable import AgentOSControl

// Serialized: these tests drive the one NSApp (activation policy) of the test host.
@Suite(.serialized) struct AppDelegateTests {
    @Test func windowsOnScreenDecideTheDockIcon() {
        #expect(AppDelegate.policy(mainWindows: 0) == .accessory)
        #expect(AppDelegate.policy(mainWindows: 1) == .regular)
        #expect(AppDelegate.policy(mainWindows: 2) == .regular)
    }

    @Test func reopenWithoutWindowShowsTheMainWindowOnce() {
        let delegate = AppDelegate()
        delegate.windows = { [] }
        var opened = 0
        delegate.openMainWindow = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(opened == 1)
    }

    @Test func reopenWithAVisibleWindowLeavesItAlone() {
        let delegate = AppDelegate()
        let window = Self.offscreenWindow(styleMask: [.titled, .closable])
        defer { Self.dispose(window) }
        window.orderFront(nil)
        delegate.windows = { [window] }
        var opened = 0
        delegate.openMainWindow = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(opened == 0)
    }

    /// A status item can make AppKit say "a window is visible" while only the menu bar panel is:
    /// the flag is not trusted, the count of real main-capable windows is.
    @Test func reopenIgnoresTheFlagWhenNoMainWindowExists() {
        let delegate = AppDelegate()
        let panel = Self.offscreenWindow(styleMask: [.titled, .nonactivatingPanel], panel: true)
        defer { Self.dispose(panel) }
        panel.orderFront(nil)
        delegate.windows = { [panel] }
        var opened = 0
        delegate.openMainWindow = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(opened == 1)
    }

    /// The MenuBarExtra panel is borderless: it must not keep the Dock icon alive, a titled window
    /// (main or Settings) must, and closing it must drop the icon again.
    @Test func onlyTitledWindowsKeepTheDockIconAlive() {
        let delegate = AppDelegate()
        let panel = Self.offscreenWindow(styleMask: [.borderless], panel: true)
        let window = Self.offscreenWindow(styleMask: [.titled, .closable])
        defer { Self.dispose(panel); Self.dispose(window) }
        delegate.windows = { [panel, window] }

        panel.orderFront(nil)
        delegate.refreshActivationPolicy()
        #expect(NSApp.activationPolicy() == .accessory)

        window.orderFront(nil)
        delegate.refreshActivationPolicy()
        #expect(NSApp.activationPolicy() == .regular)

        window.close()
        delegate.refreshActivationPolicy()
        #expect(NSApp.activationPolicy() == .accessory)
    }

    /// A titled panel (a MenuBarExtra popup can be one) is not a main window: no Dock icon for it.
    @Test func aTitledPanelOnScreenNeverGivesADockIcon() {
        let delegate = AppDelegate()
        let panel = Self.offscreenWindow(styleMask: [.titled, .nonactivatingPanel], panel: true)
        defer { Self.dispose(panel) }
        panel.orderFront(nil)
        delegate.windows = { [panel] }
        NSApp.setActivationPolicy(.regular)
        delegate.refreshActivationPolicy()
        #expect(NSApp.activationPolicy() == .accessory)
    }

    /// Off-screen, so the tests never flash a window on JT's display.
    private static func offscreenWindow(styleMask: NSWindow.StyleMask, panel: Bool = false) -> NSWindow {
        let frame = NSRect(x: -20_000, y: -20_000, width: 40, height: 40)
        let window = panel
            ? NSPanel(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func dispose(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }
}
