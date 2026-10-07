import Foundation

/// « Armer pour la nuit » (spec §15.4): one `pmset schedule wake`, authorised by JT in macOS' own
/// administrator dialog. The app never sees the password; a cancelled dialog arms nothing.
enum NightArm {
    /// What `pmset` will really do for an instant: the script to run, the instant it will wake the Mac,
    /// and, only when that is not the instant asked for, the sentence telling JT.
    struct Plan {
        let script: String
        let wake: Date
        let notice: String?
    }

    private static let pmsetFormat = "MM/dd/yy HH:mm:ss"

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    static func pmsetDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(pmsetFormat, timeZone).string(from: date)
    }

    /// When daylight-saving time ends, one hour happens twice (Paris, 2026-10-25: 02:00-02:59) and both
    /// passes format to the same string. pmset parses it like `DateFormatter.date(from:)` does, to the
    /// SECOND pass: armed from the first pass, the Mac wakes an hour late.
    static func plan(for date: Date, timeZone: TimeZone = .current) -> Plan {
        let date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))  // pmset knows whole seconds
        let parsed = formatter(pmsetFormat, timeZone).date(from: pmsetDate(date, timeZone: timeZone)) ?? date
        // A parser that took the first pass would wake the Mac before its time, and it sleeps again.
        let wake = parsed < date ? endOfRepeatedHour(after: date, timeZone: timeZone) : parsed
        let script = "do shell script \"/usr/bin/pmset schedule wake '\(pmsetDate(wake, timeZone: timeZone))'\" with administrator privileges"
        guard wake != date else { return Plan(script: script, wake: wake, notice: nil) }
        let clock = formatter("HH:mm", timeZone).string(from: wake)
        let minutes = Int(wake.timeIntervalSince(date) / 60)
        return Plan(
            script: script, wake: wake,
            notice: "Heure répétée (fin de l'heure d'été) : le Mac se réveillera à \(clock) (heure d'hiver), \(minutes) min après l'heure visée")
    }

    /// First instant after the repeated hour whose second pass contains `date` (03:00 CET for 02:35 CET);
    /// `date` itself anywhere else, never an earlier instant: no daylight-saving time, no transition behind it
    /// (the next one may be weeks away), or a spring one (the clock went forward, nothing repeats).
    static func endOfRepeatedHour(after date: Date, timeZone: TimeZone) -> Date {
        let before = date.addingTimeInterval(-3600)  // the same wall time, one pass earlier
        let shift = timeZone.daylightSavingTimeOffset(for: before) - timeZone.daylightSavingTimeOffset(for: date)
        guard shift > 0, let transition = timeZone.nextDaylightSavingTimeTransition(after: before), transition <= date
        else { return date }  // only the end of daylight-saving time (a positive shift) repeats an hour
        return transition.addingTimeInterval(shift)
    }

    /// `error` is nil when armed, else the message shown to JT; `notice` says when the Mac really wakes
    /// if that is not the instant asked for.
    @MainActor static func arm(at date: Date) -> (error: String?, notice: String?) {
        let plan = Self.plan(for: date)
        var error: NSDictionary?
        NSAppleScript(source: plan.script)?.executeAndReturnError(&error)
        return (error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "pmset a échoué" }, plan.notice)
    }
}
