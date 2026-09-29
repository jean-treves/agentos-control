import AppKit
import SwiftUI

/// Stockage (spec §16.3): disk, then the last /optimize scan by category. The app never runs a
/// clean-up: a proposed command is copied, JT runs it himself.
struct StorageView: View {
    @Environment(ControlModel.self) private var model
    @State private var snapshot = StorageSummary.Snapshot()
    @State private var message: String?
    @State private var launching = false

    var body: some View {
        List {
            ForEach(snapshot.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            Section("Disque") {
                if let disk = snapshot.disk {
                    LabeledContent("Libre", value: StorageSummary.diskLine(disk))
                    ProgressView(value: Double(disk.usedPct), total: 100)
                } else {
                    Text("Pas de mesure du disque.").foregroundStyle(.secondary)
                }
            }
            if let report = snapshot.report {
                Section("Dernier scan : \(report.generatedAt.map { String($0.prefix(10)) } ?? "?")") {
                    Text("\(report.findings.count) constats").foregroundStyle(.secondary)
                }
                ForEach(StorageSummary.grouped(report.findings), id: \.category) { group in
                    Section("\(group.category) (\(group.findings.count))") {
                        ForEach(group.findings) { FindingRow(finding: $0) }
                    }
                }
            } else {
                Section("Scan") { Text("Aucun scan : lance-le ci-dessous.").foregroundStyle(.secondary) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let message { Text(message).font(.caption) }
                Spacer()
                Button("Lancer le scan (Touch ID)") {
                    launching = true
                    Task {
                        message = await model.startScan()
                        launching = false
                    }
                }
                .disabled(launching)
            }
            .padding(8)
        }
        .task {
            await pollEvery(.seconds(60)) {
                let next = await StorageSummary.refresh(snapshot, client: model.client)
                guard !Task.isCancelled else { return }  // the screen was left: nothing to show it to
                snapshot = next
            }
        }
    }
}

private struct FindingRow: View {
    let finding: Finding
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(finding.title).font(.headline)
                Spacer()
                Text(StorageSummary.size(finding.estimatedImpactMb)).monospacedDigit()
                if let risk = finding.riskLevel {
                    Text(risk).font(.caption).padding(.horizontal, 6).background(.quaternary, in: .capsule)
                }
            }
            if let description = finding.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let command = finding.command, !command.isEmpty {
                HStack {
                    Text(command).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(copied ? "Copié" : "Copier") {
                        StorageSummary.copy(command)
                        copied = true
                    }
                }
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Pure helpers of the Storage screen (tested).
enum StorageSummary {
    struct Group {
        let category: String
        let findings: [Finding]
    }

    /// What one refresh shows. A failed call keeps the last good value; its reason goes to `problems`.
    struct Snapshot {
        var disk: DiskStatus?
        var report: OptimizeReport?
        var problems: [String] = []
    }

    /// Disk and last scan, fetched independently. 404 on the scan means none has run yet (no report,
    /// no problem).
    static func refresh(_ last: Snapshot, client: HostClient) async -> Snapshot {
        async let status = client.status()
        async let latest = client.optimizeLatest()
        var next = Snapshot(disk: last.disk, report: last.report)
        do { next.disk = try await status.disk } catch { next.problems.append("Disque : \(error.localizedDescription)") }
        do { next.report = try await latest } catch let error as HostError where error == .notFound {
            next.report = nil
        } catch {
            next.problems.append("Scan : \(error.localizedDescription)")
        }
        return next
    }

    static func diskLine(_ disk: DiskStatus) -> String {
        String(format: "%.1f Go sur %.0f Go (%d %% occupé)", disk.freeGb, disk.totalGb, disk.usedPct)
    }

    static func grouped(_ findings: [Finding]) -> [Group] {
        Dictionary(grouping: findings, by: \.category)
            .map { category, items in
                Group(category: category, findings: items.sorted {
                    ($0.estimatedImpactMb ?? -1) > ($1.estimatedImpactMb ?? -1)
                })
            }
            .sorted { lhs, rhs in
                total(lhs) != total(rhs) ? total(lhs) > total(rhs) : lhs.category < rhs.category
            }
    }

    static func total(_ group: Group) -> Double {
        group.findings.reduce(0) { $0 + ($1.estimatedImpactMb ?? 0) }
    }

    static func size(_ megabytes: Double?) -> String {
        guard let megabytes else { return "—" }
        return megabytes >= 1024 ? String(format: "%.1f Go", megabytes / 1024) : String(format: "%.0f Mo", megabytes)
    }

    /// The only thing the app does with a clean-up command: put it on the pasteboard.
    static func copy(_ command: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }
}
