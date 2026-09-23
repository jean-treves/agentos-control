import AppKit
import LocalAuthentication
import os

/// Proof that JT is at the Mac (Touch ID, or the session password as fallback). macOS ignores
/// `.authenticationRequired` on notification actions (macos-app-facts.md), so the app asks itself
/// before every approve, kill switch toggle and breaker reset. Injectable for tests.
struct HumanPresence: Sendable {
    let verify: @Sendable (_ reason: String) async -> Bool

    static let deviceOwner = HumanPresence { reason in
        // A menu bar app is usually not frontmost when a notification action arrives.
        await MainActor.run { NSApplication.shared.activate() }
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            Logger(subsystem: "com.jeantreves.agentoscontrol", category: "presence")
                .notice("presence not confirmed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
