import Foundation
import Testing
@testable import AgentOSControl

@Suite struct NightArmTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func scriptSchedulesOneWakeInPmsetFormat() {
        let date = ISO8601DateFormatter().date(from: "2026-09-29T02:03:30Z")!
        let utc = TimeZone(identifier: "UTC")!
        #expect(NightArm.pmsetDate(date, timeZone: utc) == "09/29/26 02:03:30")
        #expect(NightArm.plan(for: date, timeZone: utc).script
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

    /// 2026-10-25, Paris: 02:00-02:59 happens twice, both formatted "02:35:00". pmset's parser (the same
    /// CFDateFormatter path) takes the SECOND one, so a wake asked for the first pass comes an hour late.
    @Test func theFirstPassOfTheRepeatedHourWakesAnHourLateAndSaysSo() {
        let date = instant("2026-10-25T00:35:00Z")  // 02:35 CEST
        let plan = NightArm.plan(for: date, timeZone: paris)
        #expect(plan.script.contains("10/25/26 02:35:00"))
        #expect(plan.wake == instant("2026-10-25T01:35:00Z"))  // 02:35 CET
        #expect(plan.notice?.contains("02:35") == true)
        #expect(plan.notice?.contains("60 min") == true)  // the shift is computed, not worded
    }

    @Test func theSecondPassWakesOnTimeWithNothingToSay() {
        let date = instant("2026-10-25T01:35:00Z")  // 02:35 CET
        let plan = NightArm.plan(for: date, timeZone: paris)
        #expect(plan.script.contains("10/25/26 02:35:00"))
        #expect(plan.wake == date)
        #expect(plan.notice == nil)
    }

    @Test func afterTheRepeatedHourNothingToSay() {
        let date = instant("2026-10-25T02:35:00Z")  // 03:35 CET
        let plan = NightArm.plan(for: date, timeZone: paris)
        #expect(plan.script.contains("10/25/26 03:35:00"))
        #expect(plan.wake == date)
        #expect(plan.notice == nil)
    }

    /// 2027-03-28: 02:00-02:59 does not exist, so no real instant formats to it; the plan never invents one.
    @Test func theSpringGapNeverFormatsAnHourThatDoesNotExist() {
        let last = instant("2027-03-28T00:59:59Z")  // 01:59:59 CET
        let first = instant("2027-03-28T01:00:00Z")  // 03:00:00 CEST
        let beforeGap = NightArm.plan(for: last, timeZone: paris)
        let afterGap = NightArm.plan(for: first, timeZone: paris)
        #expect(beforeGap.script.contains("03/28/27 01:59:59"))
        #expect(afterGap.script.contains("03/28/27 03:00:00"))
        #expect(beforeGap.wake == last && beforeGap.notice == nil)
        #expect(afterGap.wake == first && afterGap.notice == nil)
    }

    /// The guard: a parser that took the FIRST pass for a second-pass time would wake the Mac an hour
    /// early (it sleeps again before the Drawback). The wake moves to 03:00 CET, just after the repeated hour.
    @Test func theGuardMovesAnEarlyWakeToTheEndOfTheRepeatedHour() {
        let secondPass = instant("2026-10-25T01:35:00Z")  // 02:35 CET
        #expect(NightArm.endOfRepeatedHour(after: secondPass, timeZone: paris)
                == instant("2026-10-25T02:00:00Z"))  // 03:00 CET
        let utc = TimeZone(identifier: "UTC")!  // no DST, no repeated hour: nothing to move to
        #expect(NightArm.endOfRepeatedHour(after: secondPass, timeZone: utc) == secondPass)
    }

    /// Only the second pass of a repeated hour has an end to move to. Anywhere else the next transition is weeks
    /// away (2026-07-14 would give 2026-10-25), a wake armed that late with a wrong notice; and just after the
    /// spring transition the offsets are reversed (2027-03-28T01:30Z would give 00:00Z, before the date).
    @Test func theGuardLeavesAnyOtherInstantWhereItIs() {
        let others = [
            "2026-07-14T10:00:00Z", "2027-01-15T10:00:00Z",  // summer, winter
            "2026-10-25T00:35:00Z",  // first pass of the repeated hour
            "2027-03-28T01:30:00Z",  // just after the spring transition: no repeated hour to end
        ]
        for iso in others {
            let date = instant(iso)
            #expect(NightArm.endOfRepeatedHour(after: date, timeZone: paris) == date, "\(iso)")
        }
    }

    /// pmset knows whole seconds: `Date()` has a fraction, and formatting then parsing drops it. That is
    /// not an early wake: the plan wakes on the whole second and has nothing to say.
    @Test func aFractionOfASecondIsNotAnEarlyWake() {
        let whole = instant("2026-10-06T01:00:00Z")
        let plan = NightArm.plan(for: whole.addingTimeInterval(0.4), timeZone: paris)
        #expect(plan.script.contains("10/06/26 03:00:00"))
        #expect(plan.wake == whole)
        #expect(plan.notice == nil)
    }
}
