import AppKit

/// Keeps AgentOS alive with its window closed, and brings the window back when JT reopens the app
/// from the Dock, the Launchpad, Spotlight or the Finder (spec §16.2).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Registered by the menu bar label, the one view alive for the whole session (decision E3).
    var openMainWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only start: no Dock icon until the window shows (MainView switches back).
        if !AppSettings.current().showWindowAtLaunch { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            openMainWindow?()
            NSApp.activate()
        }
        return true
    }
}
