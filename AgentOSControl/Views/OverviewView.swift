import os
import SwiftUI

/// Aperçu (spec §16.3): one line of status, then the former Bureau (active agents) and Santé
/// (deep checks, including `residents`) tabs, each scrolling on its own.
struct OverviewView: View {
    @Environment(ControlModel.self) private var model
    @State private var glance: Glance?
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "overview")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                badge("Host", model.hostReachable == true ? "joignable" : "injoignable",
                      ok: model.hostReachable == true)
                HStack(alignment: .bottom, spacing: 8) {
                    badge("Arrêt d'urgence", model.killSwitchOn ? "ACTIF" : "inactif", ok: !model.killSwitchOn)
                    // Same Touch ID path as the menu bar (spec §16.3: kill switch from the Overview).
                    Button(model.killSwitchOn ? "Désactiver (Touch ID)" : "Déclencher (Touch ID)") {
                        Task { await model.setKillSwitch(!model.killSwitchOn) }
                    }
                    .controlSize(.small)
                }
                badge("Disjoncteur", model.breaker.map { $0.canLaunch ? "fermé" : "ouvert" } ?? "?",
                      ok: model.breaker?.canLaunch ?? true)
                badge("Approbations", "\(model.openApprovals.count) en attente", ok: model.openApprovals.isEmpty)
                if let offers = glance?.offers {
                    badge("Veille emploi", "\(offers) offres (\(glance?.jobsDate ?? "?"))", ok: true)
                }
                Spacer()
            }
            .padding()
            Divider()
            VSplitView {
                FloorView().frame(minHeight: 160)
                HealthView().frame(minHeight: 240)
            }
        }
        .task { await pollEvery(.seconds(30)) { await loadGlance() } }
    }

    /// Keeps the last good value on a failure: the Host badge already says when the host is down.
    private func loadGlance() async {
        do { glance = try await model.client.glance() } catch {
            logger.notice("glance failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func badge(_ title: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(value, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}
