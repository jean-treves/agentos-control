import Foundation
import ServiceManagement

/// Launch-time settings. Overrides come from `defaults write com.jeantreves.agentoscontrol …` or
/// launch arguments (`-hostURL http://127.0.0.1:3107 -readOnly YES`).
nonisolated struct AppSettings: Sendable {
    let hostURL: URL
    /// Never reads the control token (so no control request can leave the app) and posts no
    /// notification. For diagnostics and for launching a build that must not act on the host.
    let readOnly: Bool
    /// Hosting the unit tests: start no poll, no socket, no notification.
    let isUnderTest: Bool
    /// false: start in the menu bar only (spec §16.2).
    let showWindowAtLaunch: Bool

    static let defaultHostURL = URL(string: "http://127.0.0.1:3107")!

    static func current(
        defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppSettings {
        AppSettings(
            hostURL: defaults.string(forKey: "hostURL").flatMap(URL.init(string:)) ?? defaultHostURL,
            readOnly: defaults.bool(forKey: "readOnly"),
            isUnderTest: environment["XCTestConfigurationFilePath"] != nil,
            // bool(forKey:) also reads the strings "YES"/"NO" that `-key NO` and `defaults write` produce.
            showWindowAtLaunch: defaults.object(forKey: "showWindowAtLaunch") == nil
                ? true : defaults.bool(forKey: "showWindowAtLaunch"))
    }

    /// JT's Obsidian vault: memory hits under it open in Obsidian.
    static func vaultPath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "vaultPath") ?? NSHomeDirectory() + "/Obsidian/JT-Vault"
    }
}

/// Open at login (SMAppService works ad hoc, without approval: macos-app-facts.md). Only offered
/// from the installed copy, otherwise the login item would point at a build folder.
enum LoginItem {
    static let installedPath = "/Applications/AgentOS.app"

    static var isAvailable: Bool { Bundle.main.bundleURL.path == installedPath }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
