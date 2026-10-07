import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import AgentOSControl

/// Out of mandate (decision D16) the host's `approve` stops the run and drafts a widened brief that waits for JT in
/// the briefs pane of Commandes, and `deny` lets the run continue without. JT clicked « Relancer avec ce mandat » on
/// E2E 32 while meaning to refuse: the card, the notification and the Touch ID sentence now say what each button does.
@Suite struct OutOfMandateTests {
    private func approval(outOfMandate: Bool) -> Approval {
        var approval = Approval(id: outOfMandate ? "o1" : "n1", ts: 1_790_000_000, capability: "terminal",
                                target: "curl example.org", runId: nil, timeoutAt: 1_790_000_300)
        if outOfMandate { approval.actionClass = "out_of_mandate" }
        return approval
    }

    /// The card builds its buttons from this wording (a hosted SwiftUI row exposes none of its text to a test), and
    /// each label travels with the host decision it sends: the card cannot put « Élargir… » on a `deny` (E2E 32).
    @Test func theCardSaysWhatEachButtonDoes() {
        func choice(
            _ title: String, approves: Bool, prominent: Bool, destructive: Bool = false
        ) -> ApprovalOrigin.Choice {
            ApprovalOrigin.Choice(title: title, approves: approves, prominent: prominent, destructive: destructive)
        }
        let out = ApprovalOrigin.wording(for: approval(outOfMandate: true))
        #expect(out.choices == [
            choice("Refuser : le run continue sans", approves: false, prominent: true),
            choice("Élargir le mandat : arrêter le run, nouveau brief (Touch ID)", approves: true, prominent: false),
        ])
        #expect(out.note == "Le brief élargi attendra ta validation dans Commandes (volet des briefs).")
        // An ordinary card is exactly what it was.
        let ordinary = ApprovalOrigin.wording(for: approval(outOfMandate: false))
        #expect(ordinary.choices == [
            choice("Approuver (Touch ID)", approves: true, prominent: true),
            choice("Refuser", approves: false, prominent: false, destructive: true),
        ])
        #expect(ordinary.note == nil)
    }

    /// E2E 32: JT clicked the highlighted button of an out-of-mandate card meaning to refuse. There the highlighted
    /// button must be the one that lets the run go on (`deny`), the other widens the mandate (`approve`); an
    /// ordinary card is the other way round.
    @Test func theHighlightedButtonSendsTheLikelyDecision() {
        for (outOfMandate, highlightedApproves) in [(true, false), (false, true)] {
            let choices = ApprovalOrigin.wording(for: approval(outOfMandate: outOfMandate)).choices
            let highlighted = choices.filter(\.prominent).map(\.approves)
            #expect(highlighted == [highlightedApproves], "out of mandate \(outOfMandate)")
            #expect(choices.first?.prominent == true)  // and it is the first, the top one when stacked
            #expect(choices.count == 2 && Set(choices.map(\.approves)) == [true, false])  // one button per decision
        }
    }

    /// The menu bar popover shows the same cards in a fixed width. The long out-of-mandate labels have to fit it,
    /// one button above the other: side by side they need about 584 pt, and the words cut are the ones this change
    /// adds (review of 7d). In every phase: beside the stack, « Touch ID… » and the spinner pushed the row over
    /// (430 and 396 pt for 388) just while the buttons are greyed out.
    @MainActor @Test func theOutOfMandateButtonsFitTheMenuBarPopover() {
        let model = ControlModel(
            client: makeClient(recorder: RequestRecorder()), presence: .deviceOwner, notifier: nil, socket: nil)
        let room = MenuBarView.popoverWidth - 2 * 16  // the popover's `.padding()`, on each side
        let phases: [ApprovalPhase] = [.pending, .awaitingPresence, .deciding(approve: true)]
        for outOfMandate in [true, false] {
            for phase in phases {
                let state = ApprovalState(approval: approval(outOfMandate: outOfMandate), phase: phase)
                let row = NSHostingView(rootView: ApprovalRow(state: state, context: nil).environment(model))
                let needs = row.fittingSize.width
                #expect(needs <= room,
                        "out of mandate \(outOfMandate), \(phase): the row needs \(needs) pt, the popover leaves \(room)")
            }
        }
    }

    @Test func theTouchIDSentenceSaysWhatApproveDoes() {
        #expect(ApprovalOrigin.approveReason(approval(outOfMandate: true))
                == "élargir le mandat de « terminal » : le run s'arrête")
        #expect(ApprovalOrigin.approveReason(approval(outOfMandate: false)) == "approuver « terminal » pour AgentOS")
    }

    /// One out-of-mandate approval (`o1`) and one ordinary (`n1`), no run attached.
    private static let pending = #"{"pending":["#
        + #"{"id":"o1","ts":1790000000,"capability":"terminal","target":"curl example.org","run_id":null,"#
        + #""timeout_at":1790000300,"action_class":"out_of_mandate"},"#
        + #"{"id":"n1","ts":1790000001,"capability":"file_write","target":"README.md","run_id":null,"#
        + #""timeout_at":1790000301}]}"#

    /// The decision a button carries is the one that reaches the host: deny asks no Touch ID, approve asks for it.
    @MainActor @Test func aButtonSendsTheDecisionItCarries() async {
        let reasons = ReasonRecorder()
        let recorder = RequestRecorder()
        let pending = Self.pending
        let client = HostClient(
            baseURL: URL(string: "http://127.0.0.1:3107")!, token: { "test-token" },
            transport: { request in
                await recorder.record(request)
                let body = request.httpMethod == "GET" ? pending : #"{"status":"ok"}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            })
        let model = ControlModel(
            client: client, presence: HumanPresence { reason in await reasons.add(reason); return true },
            notifier: nil, socket: nil)
        await model.refreshApprovals()
        await model.decide("o1", approves: false)
        #expect(await reasons.values.isEmpty)
        await model.decide("n1", approves: true)
        #expect(await reasons.values == ["approuver « file_write » pour AgentOS"])
        let posts = await recorder.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.query() ?? "" }
        #expect(posts == ["approval_id=o1&decision=deny", "approval_id=n1&decision=approve"])
    }

    /// Through the model: what Touch ID is really asked for each kind of card.
    @MainActor @Test func approvingAsksTouchIDTheSentenceOfItsKind() async {
        let reasons = ReasonRecorder()
        let model = ControlModel(
            client: makeClient(body: Self.pending, recorder: RequestRecorder()),
            presence: HumanPresence { reason in await reasons.add(reason); return false },
            notifier: nil, socket: nil)
        await model.refreshApprovals()
        await model.approve("o1")
        await model.approve("n1")
        #expect(await reasons.values == [
            "élargir le mandat de « terminal » : le run s'arrête", "approuver « file_write » pour AgentOS",
        ])
    }

    @Test func theNotificationButtonsMeanTheSameHostDecisions() {
        #expect(ApprovalNotifier.route("OUT_WIDEN") == .approve)
        #expect(ApprovalNotifier.route("OUT_DENY") == .deny)
    }

    @MainActor @Test func anOutOfMandateNotificationHasItsOwnCategory() {
        let out = ApprovalNotifier.content(for: approval(outOfMandate: true), context: nil)
        #expect(out.categoryIdentifier == "OUT_OF_MANDATE")
        #expect(ApprovalNotifier.content(for: approval(outOfMandate: false), context: nil).categoryIdentifier == "APPROVAL")
    }

    @MainActor @Test func bothCategoriesAreRegisteredWithUniqueActions() {
        let categories = ApprovalNotifier.categories()
        #expect(Set(categories.map(\.identifier)) == ["APPROVAL", "OUT_OF_MANDATE"])
        let ordinary = categories.first { $0.identifier == "APPROVAL" }
        #expect(ordinary?.actions.map(\.identifier) == ["APPROVE", "DENY"])
        let out = categories.first { $0.identifier == "OUT_OF_MANDATE" }
        #expect(out?.actions.map(\.identifier) == ["OUT_DENY", "OUT_WIDEN"])  // refusing, the likely answer, first
        #expect(out?.actions.map(\.title)
                == ["Refuser : le run continue sans", "Élargir : arrêter le run (Touch ID)"])
        let identifiers = categories.flatMap { $0.actions.map(\.identifier) }
        #expect(identifiers.count == Set(identifiers).count)  // unique across categories
    }
}
