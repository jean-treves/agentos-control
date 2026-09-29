import AppKit
import SwiftUI

/// Veille emploi (spec §16.3): job-radar's merged offers and the applications funnel.
struct JobsView: View {
    @Environment(ControlModel.self) private var model
    @State private var snapshot = JobsSummary.Snapshot()
    @State private var message: String?
    @State private var launching = false

    var body: some View {
        List {
            ForEach(snapshot.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            Section("Candidatures") {
                if let apps = snapshot.apps {
                    LabeledContent("Total", value: "\(apps.total ?? 0)")
                    ForEach(JobsSummary.funnel(apps), id: \.0) { stage, count in
                        LabeledContent(stage, value: "\(count)")
                    }
                    LabeledContent("À relancer", value: "\(apps.due?.count ?? 0)")
                }
            }
            Section(snapshot.merged.map { "Offres du \($0.reportDate ?? "?") (\($0.offers.count))" } ?? "Offres") {
                if snapshot.merged == nil {
                    Text("Aucun rapport : lance job-radar ci-dessous.").foregroundStyle(.secondary)
                }
                ForEach(JobsSummary.sorted(snapshot.merged?.offers ?? [])) { offer in
                    Button { open(offer) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(JobsSummary.stars(offer.stars)) \(offer.title)").font(.headline)
                            Text([offer.company, offer.location, offer.posted].compactMap { $0 }
                                .joined(separator: " · ")).font(.caption)
                            if let why = offer.why {
                                Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(JobsSummary.openableURL(offer.url)?.host() ?? "Pas de lien")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let message { Text(message).font(.caption) }
                Spacer()
                Button("Lancer job-radar (Touch ID)") {
                    launching = true
                    Task {
                        message = await model.runJobRadar()
                        launching = false
                    }
                }
                .disabled(launching)
            }
            .padding(8)
        }
        .task {
            await pollEvery(.seconds(120)) {
                let next = await JobsSummary.refresh(snapshot, client: model.client)
                guard !Task.isCancelled else { return }  // the screen was left: nothing to show it to
                snapshot = next
            }
        }
    }

    private func open(_ offer: JobOffer) {
        guard let url = JobsSummary.openableURL(offer.url) else {
            message = "Cette offre n'a pas de lien web : rien n'a été ouvert."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Pure helpers of the Job watch screen (tested).
enum JobsSummary {
    static let stages: [(key: String, label: String)] = [
        ("identified", "Repérées"), ("applied", "Postulées"), ("screening", "Présélection"),
        ("take_home", "Exercice"), ("onsite", "Entretiens"), ("offer", "Offres")]

    /// What one refresh shows. A failed call keeps its last good value; its reason goes to `problems`.
    struct Snapshot {
        var merged: MergedOffers?
        var apps: Applications?
        var problems: [String] = []
    }

    /// Offers and applications, fetched independently. 404 on the offers means no report yet (empty
    /// state, no problem).
    static func refresh(_ last: Snapshot, client: HostClient) async -> Snapshot {
        async let offers = client.mergedOffers()
        async let applications = client.applications()
        var next = Snapshot(merged: last.merged, apps: last.apps)
        do { next.merged = try await offers } catch let error as HostError where error == .notFound {
            next.merged = nil
        } catch {
            next.problems.append("Offres : \(error.localizedDescription)")
        }
        do { next.apps = try await applications } catch {
            next.problems.append("Candidatures : \(error.localizedDescription)")
        }
        return next
    }

    static func funnel(_ apps: Applications) -> [(String, Int)] {
        stages.compactMap { stage in apps.funnel?[stage.key].map { (stage.label, $0) } }
    }

    static func sorted(_ offers: [JobOffer]) -> [JobOffer] {
        offers.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) }
    }

    /// Clamped: `stars` is data from a scraper, and a negative repeat count would crash the screen.
    static func stars(_ count: Int?) -> String {
        String(repeating: "★", count: min(max(count ?? 0, 0), 5))
    }

    /// Offer links are scraped: only `http(s)` is ever opened. job-room links often come as
    /// `www.jobs.ch/…` (no scheme), which gets `https://`. Userinfo is refused: in
    /// `https://www.x.com@evil.com/p` the text reads x.com and the browser opens evil.com.
    static func openableURL(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("www.") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil, url.user() == nil, url.password() == nil,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
