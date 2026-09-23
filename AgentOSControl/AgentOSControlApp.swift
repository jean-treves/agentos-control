import SwiftUI

@main
struct AgentOSControlApp: App {
    @State private var model: ControlModel

    init() {
        let settings = AppSettings.current()
        let model = ControlModel.live(settings: settings)
        _model = State(initialValue: model)
        // Hosting unit tests: no poll, no socket, no notification prompt on JT's screen.
        if !settings.isUnderTest { model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: model.statusSymbol)
            if !model.openApprovals.isEmpty { Text("\(model.openApprovals.count)") }
        }
        .menuBarExtraStyle(.window)

        Window("AgentOS Control", id: "main") {
            MainView().environment(model)
        }
        .defaultSize(width: 760, height: 520)
    }
}
