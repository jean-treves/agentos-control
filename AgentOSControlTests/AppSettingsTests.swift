import Foundation
import Testing
@testable import AgentOSControl

@Suite struct AppSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "agentos-tests-\(UUID().uuidString)")!
    }

    @Test func windowShowsAtLaunchUnlessJTTurnedItOff() {
        let store = defaults()
        #expect(AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
        store.set(false, forKey: "showWindowAtLaunch")
        #expect(!AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
    }

    @Test func vaultPathDefaultsToJTsVaultAndCanBeOverridden() {
        let store = defaults()
        #expect(AppSettings.vaultPath(defaults: store) == NSHomeDirectory() + "/Obsidian/JT-Vault")
        store.set("/tmp/vault", forKey: "vaultPath")
        #expect(AppSettings.vaultPath(defaults: store) == "/tmp/vault")
    }

    @Test func loginItemTargetsTheNewApp() {
        #expect(LoginItem.installedPath == "/Applications/AgentOS.app")
    }
}
