import Foundation
import Testing
@testable import AgentOSControl

@Suite struct NightArmTests {
    @Test func scriptSchedulesOneWakeInPmsetFormat() {
        let date = ISO8601DateFormatter().date(from: "2026-09-29T02:03:30Z")!
        let utc = TimeZone(identifier: "UTC")!
        #expect(NightArm.pmsetDate(date, timeZone: utc) == "09/29/26 02:03:30")
        #expect(NightArm.script(for: date, timeZone: utc)
                == "do shell script \"/usr/bin/pmset schedule wake '09/29/26 02:03:30'\" with administrator privileges")
    }

    /// The form sends Swift's ISO 8601 (`2026-10-06T01:00:00Z`): the button arms that same instant.
    @Test func theDrawbackLaunchArmsTheTimeTheFormSent() {
        let sent = ["at": "2026-10-06T01:00:00Z", "prompt": "p"]
        #expect(CommandsView.armTime("drawback", sent)
                == ISO8601DateFormatter().date(from: "2026-10-06T01:00:00Z"))
        #expect(CommandsView.armTime("market_maker", sent) == nil)  // only Drawback wakes the Mac
        #expect(CommandsView.armTime("drawback", ["prompt": "p"]) == nil)
    }
}
