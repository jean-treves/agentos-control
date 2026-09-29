import AppKit

/// Keeps AgentOS alive with its window closed, brings the window back when JT reopens the app
/// from the Dock, the Launchpad, Spotlight or the Finder (spec §16.2), and owns the one rule for
/// the Dock icon: present while a main-capable window (main or Settings) is on screen, gone otherwise.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Registered by the menu bar label, the one view alive for the whole session (decision E3).
    var openMainWindow: (() -> Void)?
    /// The windows to count; a seam so tests do not depend on what other suites have on screen.
    var windows: () -> [NSWindow] = { NSApp.windows }
    private var observers: [any NSObjectProtocol] = []

    /// Pure so it can be tested: the Dock icon and ⌘-Tab follow the windows.
    static func policy(mainWindows: Int) -> NSApplication.ActivationPolicy {
        mainWindows > 0 ? .regular : .accessory
    }

    /// A window that deserves a Dock icon: titled, not a panel (the MenuBarExtra popup may be a
    /// titled one), on screen or minimized (a minimized window still sits in the Dock).
    static func isMainCapable(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && (window.isVisible || window.isMiniaturized)
    }

    /// The one count behind both the Dock icon and the reopen decision.
    func mainWindowCount() -> Int { windows().filter(Self.isMainCapable).count }

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

    func refreshActivationPolicy() {
        let policy = Self.policy(mainWindows: mainWindowCount())
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// The one way to bring the main window up: menu bar button and Dock reopen both come here.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// AppKit's flag is not trusted: a status item can make it true with no window of ours on
    /// screen. The count of main-capable windows decides.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if mainWindowCount() == 0 { showMainWindow() }
        return true
    }
}
