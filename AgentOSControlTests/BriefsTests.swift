import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSControl

@Suite struct BriefsTests {
    let recorder = RequestRecorder()

    @Test func decodesPendingBriefs() async throws {
        let body = #"{"briefs":[{"name":"2026-09-29-dm.md","title":"DM","status":"validé","origin":"app","project":"quant/x","output_mode":"pr","agentic_mode":"accept_diffs"}]}"#
        let briefs = try await makeClient(body: body, recorder: recorder).briefs()
        #expect(briefs.first?.outputMode == "pr" && briefs.first?.isValidated == true)
    }

    @Test func savingIsAPutWithTheTokenAndTheWholeNote() async throws {
        try await makeClient(body: #"{"name":"2026-09-29-dm.md","status":"brouillon"}"#, recorder: recorder)
            .saveBrief("2026-09-29-dm.md", text: "---\nproject: x\n---\n# DM\n")
        let request = try #require(await recorder.requests.first)
        #expect(request.httpMethod == "PUT" && request.url?.path() == "/api/briefs/2026-09-29-dm.md")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["text": "---\nproject: x\n---\n# DM\n"])
    }

    @MainActor @Test func validationWithoutPresenceSendsNothing() async {
        let model = ControlModel(client: makeClient(recorder: recorder),
                                 presence: HumanPresence { _ in false }, notifier: nil, socket: nil)
        #expect(await model.validateBrief("2026-09-29-dm.md") == false)
        #expect(await recorder.requests.isEmpty)
    }

    @Test func editingALaunchedBriefIsRefusedWithTheReason() async {
        let client = makeClient(status: 409, body: #"{"detail":"brief lancé : modification refusée"}"#,
                                recorder: recorder)
        await #expect(throws: HostError.host(409, "brief lancé : modification refusée")) {
            try await client.saveBrief("2026-09-29-dm.md", text: "x")
        }
    }

    /// The section hosts the command list and the briefs in one split: both must load on appearance.
    @MainActor @Test func theCommandsSectionLoadsTheCatalogueAndTheBriefs() async {
        let model = ControlModel(client: makeClient(body: #"{"commands":[],"briefs":[]}"#, recorder: recorder),
                                 presence: HumanPresence { _ in false }, notifier: nil, socket: nil)
        // Borderless and off screen, like SidebarTests: no Dock or key-window side effect.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CommandsView().environment(model))
        window.orderFront(nil)
        defer {
            window.close()
            window.contentView = nil
        }
        var paths: Set<String> = []
        for _ in 0..<50 where !paths.isSuperset(of: ["/api/commands", "/api/briefs"]) {
            try? await Task.sleep(for: .milliseconds(100))
            paths = Set(await recorder.requests.compactMap { $0.url?.path() })
        }
        #expect(paths.isSuperset(of: ["/api/commands", "/api/briefs"]))
    }

    @Test func obsidianLinkOpensTheNoteInTheVault() {
        #expect(BriefsView.obsidianURL(for: "2026-09-29-dm.md").absoluteString
                == "obsidian://open?vault=JT-Vault&file=05-Agent-OS/passover/2026-09-29-dm.md")
    }

    @Test func pendingDecodesTheOriginColumns() async throws {
        let body = #"{"pending":[{"id":"a1","ts":1,"capability":"terminal","target":"x","run_id":"r1","timeout_at":2,"action_class":"confirm","origin_engine":"hermes-cli","origin_model":"auto:smart","origin_mode":"accept_diffs","escalated_by":"arbiter","reason":"doute"}]}"#
        let approvals = try await makeClient(body: body, recorder: recorder).pendingApprovals()
        #expect(approvals.first?.originMode == "accept_diffs" && approvals.first?.escalatedBy == "arbiter")
    }

    @Test func originSaysWhoAsksAndWhyItReachedJT() {
        var approval = Approval(id: "a1", ts: 0, capability: "terminal", target: "rm -r ./build",
                                runId: "0f0e0d0c-aaaa", timeoutAt: 0)
        approval.originEngine = "hermes-cli"
        approval.originModel = "gemma4:31b-cloud"
        approval.originMode = "auto"
        approval.escalatedBy = "arbiter"
        approval.reason = "doute sur la cible"
        #expect(ApprovalOrigin.label(approval)
                == "gemma4:31b-cloud via Hermès · run 0f0e0d0c · Auto · remontée par l'arbitre : doute sur la cible")
        approval.actionClass = "out_of_mandate"
        approval.escalatedBy = nil
        approval.reason = "réseau"
        #expect(ApprovalOrigin.isOutOfMandate(approval))
        #expect(ApprovalOrigin.label(approval).hasSuffix("hors mandat · réseau"))
        #expect(ApprovalOrigin.engines([approval, Approval(id: "b", ts: 0, capability: nil, target: nil,
                                                           runId: nil, timeoutAt: 0)]) == ["", "hermes-cli"])
    }
}
