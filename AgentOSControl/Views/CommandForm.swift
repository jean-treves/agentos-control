import SwiftUI

/// Form built from a command's parameters (`choice`, `text`, `datetime`). Labels, descriptions and
/// choices come from the host: they are shown as plain text, never parsed as Markdown.
struct CommandForm: View {
    let spec: CommandSpec
    /// nil: sent, the sheet closes. A sentence: refused or not confirmed, shown here, sheet kept open
    /// (an error in the parent view would sit under the sheet, unseen).
    let submit: ([String: String]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Form {
            Text(verbatim: spec.description).font(.callout).foregroundStyle(.secondary)
            ForEach(spec.params, id: \.name) { field($0) }
            if let error { Text(verbatim: error).font(.callout).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear {
            values = Self.defaults(spec)
            dates = Self.defaultDates(spec)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Lancer") {
                    sending = true
                    error = nil
                    Task {
                        error = await submit(Self.payload(spec, values: values, dates: dates))
                        sending = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(!Self.isComplete(spec, values: values) || sending)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder private func field(_ param: CommandParam) -> some View {
        switch param.kind {
        case "choice":
            if (param.choices ?? []).isEmpty && param.required {
                LabeledContent(param.label) { Text("Aucun choix disponible").foregroundStyle(.secondary) }
            } else {
                Picker(param.label, selection: text(param.name)) {
                    if !param.required { Text("—").tag("") }
                    ForEach(param.choices ?? [], id: \.self) { Text(verbatim: param.labels?[$0] ?? $0).tag($0) }
                }
            }
        case "datetime":
            if param.required {
                DatePicker(param.label, selection: date(param.name))
            } else {
                // An untouched optional date must not look chosen: it is unset (and unsent) until asked.
                Toggle(isOn: dateIsSet(param.name)) { Text(verbatim: "Définir : \(param.label)") }
                if dates[param.name] != nil { DatePicker(param.label, selection: date(param.name)) }
            }
        default:
            if param.name == "prompt" || param.name == "pitch" {
                VStack(alignment: .leading) {
                    Text(verbatim: param.label)
                    TextEditor(text: text(param.name)).frame(minHeight: 100)
                }
            } else {
                TextField(param.label, text: text(param.name))
            }
        }
    }

    private func text(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func dateIsSet(_ name: String) -> Binding<Bool> {
        Binding(get: { dates[name] != nil }, set: { dates[name] = $0 ? Date() : nil })
    }

    private func date(_ name: String) -> Binding<Date> {
        Binding(get: { dates[name] ?? Date() }, set: { dates[name] = $0 })
    }

    /// The server's default, else the first choice of a required list.
    static func defaults(_ spec: CommandSpec) -> [String: String] {
        var out: [String: String] = [:]
        for p in spec.params where p.kind != "datetime" {
            if let value = p.defaultValue ?? (p.kind == "choice" && p.required ? p.choices?.first : nil) {
                out[p.name] = value
            }
        }
        return out
    }

    /// The server's default date; a required date without a readable default starts at now, so the
    /// picker shows exactly what is sent. An optional date stays unset (and unsent) until JT picks one.
    static func defaultDates(_ spec: CommandSpec) -> [String: Date] {
        var out: [String: Date] = [:]
        for p in spec.params where p.kind == "datetime" {
            if let raw = p.defaultValue, let date = parseISO(raw) {
                out[p.name] = date
            } else if p.required {
                out[p.name] = Date()
            }
        }
        return out
    }

    static func payload(_ spec: CommandSpec, values: [String: String], dates: [String: Date]) -> [String: String] {
        var out = values.filter { !$0.value.isEmpty }
        let iso = ISO8601DateFormatter()
        for p in spec.params where p.kind == "datetime" {
            if let date = dates[p.name] ?? (p.required ? Date() : nil) { out[p.name] = iso.string(from: date) }
        }
        return out
    }

    static func isComplete(_ spec: CommandSpec, values: [String: String]) -> Bool {
        spec.params.allSatisfy { !$0.required || $0.kind == "datetime" || !(values[$0.name] ?? "").isEmpty }
    }

    /// Python's `isoformat()`: with or without fractional seconds, with an offset or naive. A naive
    /// date is UTC, as the host reads it (`replace(tzinfo=UTC)`), whatever this Mac's time zone.
    static func parseISO(_ raw: String) -> Date? {
        let utc = TimeZone(identifier: "GMT")
        let naive: ISO8601DateFormatter.Options = [.withFullDate, .withTime, .withColonSeparatorInTime]
        // Fractional layouts first: the naive one without fractions would quietly drop the `.250000`.
        let layouts: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            naive.union(.withFractionalSeconds), naive,
        ]
        for layout in layouts {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = layout
            formatter.timeZone = utc
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
