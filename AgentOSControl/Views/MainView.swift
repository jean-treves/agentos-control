import SwiftUI

/// The window opened from the menu bar. T6.4 adds the other tabs.
struct MainView: View {
    var body: some View {
        TabView {
            Tab("Approbations", systemImage: "hand.raised") { ApprovalsView() }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
