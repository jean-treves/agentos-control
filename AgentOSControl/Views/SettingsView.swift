import SwiftUI

/// ⌘, (spec §16.2): opening at login, and whether the window shows at launch.
struct SettingsView: View {
    @AppStorage("showWindowAtLaunch") private var showWindowAtLaunch = true
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Ouvrir à la connexion", isOn: $opensAtLogin)
                .disabled(!LoginItem.isAvailable)
                .help(LoginItem.isAvailable ? "" : "Seulement depuis \(LoginItem.installedPath)")
                .onChange(of: opensAtLogin) { _, enabled in
                    // A failed register() flips the toggle back: that echo must not call unregister(),
                    // whose error would replace the real one.
                    guard enabled != LoginItem.isEnabled else { return }
                    setLoginItem(enabled)
                }
            Toggle("Afficher la fenêtre au lancement", isOn: $showWindowAtLaunch)
            Text("Sur non, AgentOS démarre dans la barre des menus seulement (effet au prochain lancement).")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func setLoginItem(_ enabled: Bool) {
        do { try LoginItem.set(enabled); error = nil } catch {
            self.error = "Ouverture à la connexion : \(error.localizedDescription)"
        }
        opensAtLogin = LoginItem.isEnabled
    }
}
