import SwiftUI

/// T6.2 placeholder so the target links; T6.3 replaces this file with the real menu bar app.
@main
struct AgentOSControlApp: App {
    var body: some Scene {
        MenuBarExtra("AgentOS", systemImage: "circle.dashed") {
            Button("Quitter") { NSApplication.shared.terminate(nil) }
        }
    }
}
