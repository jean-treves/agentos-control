import SwiftUI

/// The AgentOS window (spec §16.3): a sidebar of sections; each screen polls only while shown.
struct MainView: View {
    @Environment(ControlModel.self) private var model
    @SceneStorage("section") private var section: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .approvals ? model.openApprovals.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail(section).navigationTitle(section.title)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { section }, set: { if let item = $0 { section = item } })
    }

    @ViewBuilder private func detail(_ item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .approvals: ApprovalsView()
        case .runs: RunsView()
        case .tasks: TasksView()
        }
    }
}

/// Sidebar sections, in display order.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, approvals, runs, tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Aperçu"
        case .approvals: "Approbations"
        case .runs: "Runs"
        case .tasks: "Tâches"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .approvals: "hand.raised"
        case .runs: "list.bullet.rectangle"
        case .tasks: "checklist"
        }
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
