import Foundation
import Testing
@testable import AgentOSControl

@Suite struct AppSettingsTests {
    /// Runs `body` on a throwaway defaults suite, then removes it. A path as suite name puts the
    /// plist in the temp dir: a named suite in ~/Library/Preferences leaves a file per test, even
    /// after removePersistentDomain (cfprefsd rewrites it later).
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let domain = NSTemporaryDirectory() + "agentos-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: domain)!
        defer {
            store.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(atPath: domain + ".plist")
        }
        body(store)
    }

    @Test func windowShowsAtLaunchUnlessJTTurnedItOff() {
        withDefaults { store in
            #expect(AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
            store.set(false, forKey: "showWindowAtLaunch")
            #expect(!AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
        }
    }

    /// `-showWindowAtLaunch NO` and `defaults write … showWindowAtLaunch NO` store a string, like
    /// `-readOnly YES` does; both must turn the window off.
    @Test func windowSettingAcceptsStringOverrides() {
        withDefaults { store in
            store.set("NO", forKey: "showWindowAtLaunch")
            #expect(!AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
            store.set("YES", forKey: "showWindowAtLaunch")
            #expect(AppSettings.current(defaults: store, environment: [:]).showWindowAtLaunch)
        }
    }

    @Test func vaultPathDefaultsToJTsVaultAndCanBeOverridden() {
        withDefaults { store in
            #expect(AppSettings.vaultPath(defaults: store) == NSHomeDirectory() + "/Obsidian/JT-Vault")
            store.set("/tmp/vault", forKey: "vaultPath")
            #expect(AppSettings.vaultPath(defaults: store) == "/tmp/vault")
        }
    }

    @Test func loginItemTargetsTheNewApp() {
        #expect(LoginItem.installedPath == "/Applications/AgentOS.app")
    }
}
