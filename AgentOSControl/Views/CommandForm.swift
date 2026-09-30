import SwiftUI

/// Form built from a command's parameters (`choice`, `text`, `datetime`). Labels, descriptions and
/// choices come from the host: they are shown as plain text, never parsed as Markdown.
struct CommandForm: View {
    let spec: CommandSpec
    let submit: ([String: String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var sending = false

    var body: some View {
        Form {
            Text(verbatim: spec.description).font(.callout).foregroundStyle(.secondary)
            ForEach(spec.params, id: \.name) { field($0) }
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
                    Task {
                        if await submit(Self.payload(spec, values: values, dates: dates)) { dismiss() }
                        sending = false
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
            DatePicker(param.label, selection: date(param.name))
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

    /// Python's `isoformat()`: with or without fractional seconds, with an offset or naive (local time,
    /// as `datetime.fromisoformat` would be read by the host's own clock).
    static func parseISO(_ raw: String) -> Date? {
        let zoned = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let naive = ISO8601DateFormatter()
        naive.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        naive.timeZone = .current
        return zoned.date(from: raw) ?? fractional.date(from: raw) ?? naive.date(from: raw)
    }
}
