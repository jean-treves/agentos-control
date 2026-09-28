import AppKit
import SwiftUI

@main
struct AgentOSControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: ControlModel
    private let settings: AppSettings

    init() {
        let settings = AppSettings.current()
        self.settings = settings
        let model = ControlModel.live(settings: settings)
        _model = State(initialValue: model)
        // Hosting unit tests: no poll, no socket, no notification prompt on JT's screen.
        if !settings.isUnderTest { model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel(model: model, delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("AgentOS", id: "main") {
            MainView().environment(model)
                // A window on screen: Dock icon and Cmd-Tab; closed: menu bar only (spec §16.2).
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1040, height: 660)
        .defaultLaunchBehavior(settings.showWindowAtLaunch && !settings.isUnderTest ? .presented : .suppressed)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Status icon of the menu bar; also hands the delegate a way to open the window (decision E3).
private struct MenuBarLabel: View {
    let model: ControlModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: model.statusSymbol)
            if !model.openApprovals.isEmpty { Text("\(model.openApprovals.count)") }
        }
        .onAppear { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}
