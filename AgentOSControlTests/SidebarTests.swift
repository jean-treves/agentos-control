import Testing
@testable import AgentOSControl

@Suite struct SidebarTests {
    @Test func sectionsInTheOrderOfSpec16() {
        #expect(SidebarItem.allCases.map(\.title) == ["Aperçu", "Approbations", "Runs", "Tâches"])
        #expect(Set(SidebarItem.allCases.map(\.symbol)).count == SidebarItem.allCases.count)
    }
}
