import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSControl

/// Serves each route its own answer; anything else is a 404. Records every request.
private func pathClient(_ routes: [String: (Int, String)], recorder: RequestRecorder) -> HostClient {
    HostClient(
        baseURL: URL(string: "http://127.0.0.1:3107")!,
        token: { "test-token" },
        transport: { request in
            await recorder.record(request)
            let (status, body) = routes[request.url?.path() ?? ""] ?? (404, "{}")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
}

private let diskBody = #"{"disk":{"free_gb":77.7,"total_gb":460.4,"used_pct":83}}"#
private let reportBody = #"{"generated_at":"2026-09-11T17:41:22+00:00","findings":[{"id":"f1","category":"disk","title":"t","description":null,"command":null,"risk_level":"low","one_click_safe":false,"estimated_impact_mb":12}]}"#
private let mergedBody = #"{"offers":[{"stars":2,"title":"Quant","company":"C","url":"https://example.invalid/o","why":"w","location":"Genève","country":"CH","posted":"2026-09-27","source":"pme"}],"offers_count":1,"report_date":"2026-09-28","producers":{"pme":1}}"#
private let appsBody = #"{"total":1,"funnel":{"identified":1},"due":[{"id":"a"}],"schema_version":1}"#

@Suite struct StorageJobsTests {
    private func finding(_ id: String, _ category: String, _ mb: Double?, command: String? = nil) -> Finding {
        Finding(id: id, category: category, title: id, description: nil, command: command,
                riskLevel: "low", oneClickSafe: false, estimatedImpactMb: mb)
    }

    @Test func sizeAndGroupingOfFindings() {
        let groups = StorageSummary.grouped([
            finding("dl", "disk", 2458), finding("desk", "disk", nil),
            finding("uv", "cache", 3100), finding("npm", "cache", 900)])
        #expect(groups.map(\.category) == ["cache", "disk"])  // 4000 Mo before 2458 Mo
        #expect(groups[1].findings.map(\.id) == ["dl", "desk"])  // no size last
        #expect(StorageSummary.size(nil) == "—" && StorageSummary.size(900) == "900 Mo")
        #expect(StorageSummary.size(3100) == "3.0 Go")
        #expect(StorageSummary.diskLine(DiskStatus(freeGb: 77.7, totalGb: 460.4, usedPct: 83)) == "77.7 Go sur 460 Go (83 % occupé)")
    }

    @Test func offersByStarsAndFunnelInStageOrder() {
        let offers = [JobOffer(title: "A", company: "X", url: nil, stars: 1, why: nil, location: nil,
                               country: nil, posted: nil, source: nil),
                      JobOffer(title: "B", company: "Y", url: nil, stars: 3, why: nil, location: nil,
                               country: nil, posted: nil, source: nil)]
        #expect(JobsSummary.sorted(offers).map(\.title) == ["B", "A"])
        let apps = Applications(total: 2, funnel: ["applied": 1, "identified": 4, "offer": 0], due: nil)
        #expect(JobsSummary.funnel(apps).map(\.0) == ["Repérées", "Postulées", "Offres"])
    }

    @Test func launchRepliesReadAsASentence() {
        #expect(ControlModel.describe(LaunchReply(started: true, reason: nil), label: "Analyse") == "Analyse lancée")
        #expect(ControlModel.describe(LaunchReply(started: false, reason: "scan already running"), label: "Analyse")
                == "Analyse non lancée : scan already running")
        #expect(ControlModel.describe(LaunchReply(started: false, reason: nil), label: "job-radar")
                == "job-radar non lancée : raison inconnue")
    }

    @Test func starsAreClampedSoBadDataCannotCrashTheScreen() {
        #expect(JobsSummary.stars(2) == "★★" && JobsSummary.stars(nil) == "" && JobsSummary.stars(0) == "")
        #expect(JobsSummary.stars(-3) == "" && JobsSummary.stars(1_000_000) == "★★★★★")
    }

    /// A private pasteboard: the test must never touch JT's clipboard.
    @Test func copyingACommandOnlyPutsItOnThePasteboard() {
        let pasteboard = NSPasteboard(name: .init("agentos-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        StorageSummary.copy("rm -rf ~/.cache/uv", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "rm -rf ~/.cache/uv")
    }

    /// Offer links are scraped: only http(s) is ever opened. Real data (2026-09-29): 4 of 46 job-room
    /// links come without a scheme (`www.jobs.ch/…`).
    @Test func onlyWebLinksAreOpenedAndASchemelessWwwLinkGetsHTTPS() {
        #expect(JobsSummary.openableURL("https://example.invalid/o?a=1")?.absoluteString == "https://example.invalid/o?a=1")
        #expect(JobsSummary.openableURL("http://example.invalid/o")?.scheme == "http")
        #expect(JobsSummary.openableURL("www.jobs.ch/de/x/detail/1")?.absoluteString == "https://www.jobs.ch/de/x/detail/1")
        for raw in [nil, "", "  ", "file:///Applications/Calculator.app", "javascript:alert(1)", "ftp://example.invalid/a",
                    "x-apple.systempreferences:", "obsidian://open?path=/x", "example.invalid/no-scheme-no-www"] {
            #expect(JobsSummary.openableURL(raw) == nil, "\(raw ?? "nil")")
        }
    }
}

@Suite struct StorageRefreshTests {
    let recorder = RequestRecorder()

    @Test func diskAndReportLoadTogether() async {
        let client = pathClient(["/api/status": (200, diskBody), "/api/optimize/latest": (200, reportBody)], recorder: recorder)
        let state = await StorageSummary.refresh(.init(), client: client)
        #expect(state.disk?.usedPct == 83 && state.report?.findings.count == 1 && state.problems.isEmpty)
    }

    /// 404 before the first scan is "no report yet", not a failure; and it clears an older report.
    @Test func noReportYetIsNotAnErrorAndClearsTheOldReport() async {
        let client = pathClient(["/api/status": (200, diskBody)], recorder: recorder)
        let old = StorageSummary.Snapshot(disk: nil, report: OptimizeReport(generatedAt: "x", findings: []), problems: [])
        let state = await StorageSummary.refresh(old, client: client)
        #expect(state.report == nil && state.problems.isEmpty && state.disk?.freeGb == 77.7)
    }

    @Test func aFailedLoadKeepsTheLastGoodValueAndSaysWhy() async {
        let last = StorageSummary.Snapshot(
            disk: DiskStatus(freeGb: 1, totalGb: 2, usedPct: 50),
            report: OptimizeReport(generatedAt: "2026-09-11", findings: []), problems: [])
        let client = pathClient(["/api/status": (500, "{}"), "/api/optimize/latest": (500, "{}")], recorder: recorder)
        let state = await StorageSummary.refresh(last, client: client)
        #expect(state.disk?.usedPct == 50 && state.report?.generatedAt == "2026-09-11")
        #expect(state.problems == ["Disque : Erreur HTTP 500.", "Scan : Erreur HTTP 500."])
    }

    @Test func aStatusWithoutDiskShowsNoDiskAndNoError() async {
        let client = pathClient(["/api/status": (200, #"{"load":[1,2,3]}"#), "/api/optimize/latest": (200, reportBody)],
                                recorder: recorder)
        let state = await StorageSummary.refresh(.init(), client: client)
        #expect(state.disk == nil && state.problems.isEmpty)
    }
}

@Suite struct JobsRefreshTests {
    let recorder = RequestRecorder()

    @Test func offersAndApplicationsLoadTogether() async {
        let client = pathClient(
            ["/api/jobsearch/merged": (200, mergedBody), "/api/jobsearch/applications": (200, appsBody)], recorder: recorder)
        let state = await JobsSummary.refresh(.init(), client: client)
        #expect(state.merged?.offers.count == 1 && state.apps?.due?.count == 1 && state.problems.isEmpty)
    }

    @Test func aFailedApplicationsCallKeepsItsLastValueAndDoesNotHideTheOffers() async {
        let last = JobsSummary.Snapshot(merged: nil, apps: Applications(total: 9, funnel: nil, due: nil), problems: [])
        let client = pathClient(
            ["/api/jobsearch/merged": (200, mergedBody), "/api/jobsearch/applications": (500, "{}")], recorder: recorder)
        let state = await JobsSummary.refresh(last, client: client)
        #expect(state.merged?.offers.count == 1 && state.apps?.total == 9)
        #expect(state.problems == ["Candidatures : Erreur HTTP 500."])
    }

    @Test func noReportYetIsAnEmptyStateNotAnError() async {
        let client = pathClient(["/api/jobsearch/applications": (200, appsBody)], recorder: recorder)  // merged: 404
        let state = await JobsSummary.refresh(.init(), client: client)
        #expect(state.merged == nil && state.problems.isEmpty && state.apps?.total == 1)
    }

    @Test func aFailedOffersCallKeepsTheLastOffers() async {
        let good = pathClient(["/api/jobsearch/merged": (200, mergedBody), "/api/jobsearch/applications": (200, appsBody)],
                              recorder: recorder)
        let first = await JobsSummary.refresh(.init(), client: good)
        let down = pathClient(["/api/jobsearch/merged": (502, "{}"), "/api/jobsearch/applications": (200, appsBody)],
                              recorder: recorder)
        let second = await JobsSummary.refresh(first, client: down)
        #expect(second.merged?.offers.count == 1)
        #expect(second.problems == ["Offres : Erreur HTTP 502."])
    }
}

/// Launches are Touch ID-gated control routes: nothing leaves the app without JT's presence.
@Suite struct LaunchTests {
    let recorder = RequestRecorder()

    private func model(present: Bool, routes: [String: (Int, String)]) -> ControlModel {
        ControlModel(
            client: pathClient(routes, recorder: recorder), presence: HumanPresence { _ in present },
            notifier: nil, socket: nil)
    }

    private func posts() async -> [String] {
        await recorder.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.path() ?? "" }
    }

    @Test func aRefusedTouchIDSendsNothing() async {
        let model = model(present: false, routes: [:])
        #expect(await model.startScan() == "Annulé")
        #expect(await model.runJobRadar() == "Annulé")
        #expect(await recorder.requests.isEmpty)
    }

    @Test func scanAndJobRadarPostTheirOwnRouteWithTheBearer() async {
        let model = model(present: true, routes: [
            "/api/optimize/run": (200, #"{"started":true,"pid":4242}"#),
            "/api/jobsearch/run": (200, #"{"started":false,"reason":"job-radar already running"}"#)])
        #expect(await model.startScan() == "Analyse lancée")
        #expect(await model.runJobRadar() == "job-radar non lancée : job-radar already running")
        #expect(await posts() == ["/api/optimize/run", "/api/jobsearch/run"])
        let auth = await recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer test-token", "Bearer test-token"])
    }

    @Test func aRejectedLaunchIsShownAndRecorded() async {
        let model = model(present: true, routes: ["/api/optimize/run": (503, "{}")])
        #expect(await model.startScan() == "Le host n'a pas de jeton de contrôle (503).")
        #expect(model.lastError == "Le host n'a pas de jeton de contrôle (503).")
    }
}

/// The screens hosted for real (borderless, off screen, like SidebarTests): on appearing they poll their GET
/// routes and never launch anything.
@MainActor @Suite struct ScreenSmokeTests {
    let recorder = RequestRecorder()

    private func requestsSeen<V: View>(_ view: V, until expected: Set<String>) async -> [String] {
        let model = ControlModel(
            client: pathClient([
                "/api/status": (200, diskBody), "/api/optimize/latest": (200, reportBody),
                "/api/jobsearch/merged": (200, mergedBody), "/api/jobsearch/applications": (200, appsBody)],
                recorder: recorder),
            presence: HumanPresence { _ in false }, notifier: nil, socket: nil)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.environment(model))
        window.orderFront(nil)
        defer {
            window.close()
            window.contentView = nil
        }
        var seen: [String] = []
        for _ in 0..<50 where !expected.isSubset(of: seen) {
            try? await Task.sleep(for: .milliseconds(100))
            seen = await recorder.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        }
        return seen
    }

    @Test func storageScreenPollsDiskAndScanAndLaunchesNothing() async {
        let seen = await requestsSeen(StorageView(), until: ["GET /api/status", "GET /api/optimize/latest"])
        #expect(Set(seen) == ["GET /api/status", "GET /api/optimize/latest"])
    }

    @Test func jobsScreenPollsOffersAndApplicationsAndLaunchesNothing() async {
        let seen = await requestsSeen(JobsView(), until: ["GET /api/jobsearch/merged", "GET /api/jobsearch/applications"])
        #expect(Set(seen) == ["GET /api/jobsearch/merged", "GET /api/jobsearch/applications"])
    }
}
