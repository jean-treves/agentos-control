import SwiftUI

/// The window opened from the menu bar.
struct MainView: View {
    var body: some View {
        TabView {
            Tab("Approbations", systemImage: "hand.raised") { ApprovalsView() }
            Tab("Runs", systemImage: "list.bullet.rectangle") { RunsView() }
            Tab("Tâches", systemImage: "checklist") { TasksView() }
            Tab("Santé", systemImage: "stethoscope") { HealthView() }
            Tab("Bureau", systemImage: "person.3") { FloorView() }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// Runs `work` now, then every `interval`, until the calling `.task` is cancelled: screens poll
/// only while they are on screen.
func pollEvery(_ interval: Duration, _ work: () async -> Void) async {
    while !Task.isCancelled {
        await work()
        try? await Task.sleep(for: interval)
    }
}
