import AppKit
import Testing
@testable import AgentOSControl

// Serialized: these tests drive the one NSApp (activation policy) of the test host.
@Suite(.serialized) struct AppDelegateTests {
    @Test func windowsOnScreenDecideTheDockIcon() {
        #expect(AppDelegate.policy(visibleTitledWindows: 0) == .accessory)
        #expect(AppDelegate.policy(visibleTitledWindows: 1) == .regular)
        #expect(AppDelegate.policy(visibleTitledWindows: 2) == .regular)
    }

    @Test func reopenWithoutWindowShowsTheMainWindowOnce() {
        let delegate = AppDelegate()
        var opened = 0
        delegate.openMainWindow = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(opened == 1)
    }

    @Test func reopenWithAVisibleWindowLeavesItAlone() {
        let delegate = AppDelegate()
        var opened = 0
        delegate.openMainWindow = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(opened == 0)
    }

    /// The MenuBarExtra panel is borderless: it must not keep the Dock icon alive, a titled window
    /// (main or Settings) must, and closing it must drop the icon again.
    @Test func onlyTitledWindowsKeepTheDockIconAlive() {
        let delegate = AppDelegate()
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        window.isReleasedWhenClosed = false
        defer { panel.close(); window.close() }

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
}
