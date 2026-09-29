import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(ControlModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(statusLine, systemImage: model.statusSymbol).font(.headline)
            if model.notificationsAuthorized == false {
                Button("Notifications désactivées : ouvrir Réglages…") { openNotificationSettings() }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            Text("Approbations en attente (\(model.openApprovals.count))").font(.subheadline.bold())
            ForEach(model.openApprovals) { state in
                ApprovalRow(state: state, context: model.contexts[state.id])
            }
            Divider()
            Text("Runs actifs (\(model.activeRuns.count))").font(.subheadline.bold())
            ForEach(model.activeRuns.prefix(5)) { run in
                Text("\(run.source ?? "?") · \(run.prompt ?? "")").font(.caption).lineLimit(1)
            }
            Divider()
            Button(model.killSwitchOn ? "Désactiver l'arrêt d'urgence (Touch ID)" : "Arrêt d'urgence (Touch ID)") {
                Task { await model.setKillSwitch(!model.killSwitchOn) }
            }
            HStack {
                Button("Ouvrir AgentOS") { delegate.showMainWindow() }
                // Not SettingsLink: an accessory app must become regular and active first, or the
                // Settings window opens behind the other windows.
                Button("Réglages…") {
                    NSApp.setActivationPolicy(.regular)
                    openSettings()
                    NSApplication.shared.activate()
                }
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 380)
    }

    private var statusLine: String {
        switch model.hostReachable {
        case nil: return "Connexion au host…"
        case false?: return "Host injoignable"
        case true?: break
        }
        if model.killSwitchOn { return "Arrêt d'urgence ACTIF" }
        if let breaker = model.breaker, !breaker.canLaunch {
            return "Disjoncteur ouvert : \(breaker.reason ?? "?")"
        }
        return "Host OK"
    }

    private func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.jeantreves.agentoscontrol")!
        NSWorkspace.shared.open(url)
    }
}
