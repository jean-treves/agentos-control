import SwiftUI

/// `/api/health/deep` checks, plus breaker and kill switch; breaker reset under Touch ID.
struct HealthView: View {
    @Environment(ControlModel.self) private var model
    @State private var deep: DeepHealth?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Host") {
                LabeledContent("Joignable", value: model.hostReachable == true ? "oui" : "non")
                LabeledContent("Arrêt d'urgence", value: model.killSwitchOn ? "ACTIF" : "inactif")
                LabeledContent("Disjoncteur", value: breakerText)
                Button("Réarmer le disjoncteur (Touch ID)") { Task { await model.resetBreaker() } }
                    .disabled(model.breaker?.canLaunch ?? true)
            }
            Section("Contrôles profonds") {
                if let deep {
                    ForEach(deep.checks) { check in
                        LabeledContent {
                            Text(check.detail ?? "").lineLimit(2).textSelection(.enabled)
                        } label: {
                            Label(check.name, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(check.ok ? .green : .red)
                        }
                    }
                    if let generated = deep.generated {
                        Text("Mesuré \(generated, style: .relative)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task {
            await pollEvery(.seconds(30)) {
                await model.refreshStatus()
                do {
                    deep = try await model.client.deepHealth()
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private var breakerText: String {
        guard let breaker = model.breaker else { return "?" }
        if breaker.canLaunch { return "fermé (\(breaker.consecutiveFailures ?? 0) échec(s) de suite)" }
        return "ouvert : \(breaker.reason ?? "?")"
    }
}
