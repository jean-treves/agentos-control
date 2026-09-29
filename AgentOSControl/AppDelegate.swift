import AppKit

/// Keeps AgentOS alive with its window closed, brings the window back when JT reopens the app
/// from the Dock, the Launchpad, Spotlight or the Finder (spec §16.2), and owns the one rule for
/// the Dock icon: present while a titled window (main or Settings) is on screen, gone otherwise.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Registered by the menu bar label, the one view alive for the whole session (decision E3).
    var openMainWindow: (() -> Void)?
    private var observers: [any NSObjectProtocol] = []

    /// Pure so it can be tested: the Dock icon and ⌘-Tab follow the windows.
    static func policy(visibleTitledWindows: Int) -> NSApplication.ActivationPolicy {
        visibleTitledWindows > 0 ? .regular : .accessory
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only start: no Dock icon until a window shows (refreshActivationPolicy).
        if !AppSettings.current().showWindowAtLaunch { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActivationPolicy() }
            },
            // The closing window is still visible while this fires: recount on the next turn.
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshActivationPolicy() }
            },
        ]
    }

    /// Counts titled windows only: the MenuBarExtra panel is borderless and must not keep the Dock
    /// icon alive. A minimized window still sits in the Dock, so it counts.
    func refreshActivationPolicy() {
        let count = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }.count
        let policy = Self.policy(visibleTitledWindows: count)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// The one way to bring the main window up: menu bar button and Dock reopen both come here.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
}
