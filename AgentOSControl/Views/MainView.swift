import AppKit
import SwiftUI

/// The AgentOS window (spec §16.3): a sidebar of sections; each screen polls only while shown.
struct MainView: View {
    @Environment(ControlModel.self) private var model
    @SceneStorage("section") private var section: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            // id: \.self, not the Identifiable id: the rows must be tagged with the SidebarItem itself, or
            // a click stores a String tag the SidebarItem? binding cannot take and nothing gets selected.
            List(SidebarItem.allCases, id: \.self, selection: selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .approvals ? model.openApprovals.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail(section).navigationTitle(section.title)
        }
        .frame(minWidth: 900, minHeight: 560)
        // A click on an approval's notification asks for its card. `initial`: with the window closed, the
        // request is set before this view exists, so no change would ever be seen.
        // Deferred by an open sheet, the request does not expire: a window opened later honours it once.
        .onChange(of: model.revealedApprovalID, initial: true) { _, id in
            if Self.shouldSwitchSection(revealed: id, windows: NSApp.windows) { section = .approvals }
        }
    }

    /// A click on an approval's notification switches to Approbations, except while a sheet is open: leaving the
    /// section removes the view that presents it, and the sheet with what JT typed (a Drawback prompt, a review).
    /// The request stays pending; ApprovalsView takes it when JT opens the section himself.
    static func shouldSwitchSection(revealed: String?, windows: [NSWindow]) -> Bool {
        revealed != nil && !windows.contains { $0.attachedSheet != nil }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { section }, set: { if let item = $0 { section = item } })
    }

    @ViewBuilder private func detail(_ item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .conversation: ConversationView()
        case .commands: CommandsView()
        case .approvals: ApprovalsView()
        case .runs: RunsView()
        case .tasks: TasksView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .jobs: JobsView()
        case .wiki: WikiView()
        }
    }
}

/// Sidebar sections, in display order.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, conversation, commands, approvals, runs, tasks, memory, storage, jobs, wiki

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Aperçu"
        case .conversation: "Conversation"
        case .commands: "Commandes"
        case .approvals: "Approbations"
        case .runs: "Runs"
        case .tasks: "Tâches"
        case .memory: "Mémoire"
        case .storage: "Stockage"
        case .jobs: "Veille emploi"
        case .wiki: "Wiki"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .conversation: "bubble.left.and.bubble.right"
        case .commands: "bolt"
        case .approvals: "hand.raised"
        case .runs: "list.bullet.rectangle"
        case .tasks: "checklist"
        case .memory: "brain"
        case .storage: "internaldrive"
        case .jobs: "briefcase"
        case .wiki: "book.closed"
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
