import Foundation

/// « Armer pour la nuit » (spec §15.4): one `pmset schedule wake`, authorised by JT in macOS' own
/// administrator dialog. The app never sees the password; a cancelled dialog arms nothing.
enum NightArm {
    static func pmsetDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }

    static func script(for date: Date, timeZone: TimeZone = .current) -> String {
        "do shell script \"/usr/bin/pmset schedule wake '\(pmsetDate(date, timeZone: timeZone))'\" with administrator privileges"
    }

    /// nil when armed, else the message shown to JT.
    @MainActor static func arm(at date: Date) -> String? {
        var error: NSDictionary?
        NSAppleScript(source: script(for: date))?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "pmset a échoué" }
    }
}
