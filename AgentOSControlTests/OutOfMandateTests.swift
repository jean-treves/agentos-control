import Foundation
import Testing
import UserNotifications
@testable import AgentOSControl

/// Out of mandate (decision D16) the host's `approve` stops the run and drafts a widened brief that waits for JT in
/// Commandes ▸ Passover, and `deny` lets the run continue without. JT clicked « Relancer avec ce mandat » on E2E 32
/// while meaning to refuse: the card, the notification and the Touch ID sentence now say what each button does.
@Suite struct OutOfMandateTests {
    private func approval(outOfMandate: Bool) -> Approval {
        var approval = Approval(id: outOfMandate ? "o1" : "n1", ts: 1_790_000_000, capability: "terminal",
                                target: "curl example.org", runId: nil, timeoutAt: 1_790_000_300)
        if outOfMandate { approval.actionClass = "out_of_mandate" }
        return approval
    }

    /// The card builds its buttons from this wording (a hosted SwiftUI row exposes none of its text to a test).
    @Test func theCardSaysWhatEachButtonDoes() {
        #expect(ApprovalOrigin.wording(for: approval(outOfMandate: true)) == ApprovalOrigin.Wording(
            approve: "Élargir le mandat : arrêter le run, nouveau brief (Touch ID)",
            deny: "Refuser : le run continue sans",
            note: "Le brief élargi attendra ta validation dans Commandes ▸ Passover."))
        // An ordinary card is exactly what it was.
        #expect(ApprovalOrigin.wording(for: approval(outOfMandate: false)) == ApprovalOrigin.Wording(
            approve: "Approuver (Touch ID)", deny: "Refuser", note: nil))
    }

    @Test func theTouchIDSentenceSaysWhatApproveDoes() {
        #expect(ApprovalOrigin.approveReason(approval(outOfMandate: true))
                == "élargir le mandat de « terminal » : le run s'arrête")
        #expect(ApprovalOrigin.approveReason(approval(outOfMandate: false)) == "approuver « terminal » pour AgentOS")
    }

    /// Through the model: what Touch ID is really asked for each kind of card.
    @MainActor @Test func approvingAsksTouchIDTheSentenceOfItsKind() async {
        let reasons = ReasonRecorder()
        let pending = #"{"pending":["#
            + #"{"id":"o1","ts":1790000000,"capability":"terminal","target":"curl example.org","run_id":null,"#
            + #""timeout_at":1790000300,"action_class":"out_of_mandate"},"#
            + #"{"id":"n1","ts":1790000001,"capability":"file_write","target":"README.md","run_id":null,"#
            + #""timeout_at":1790000301}]}"#
        let model = ControlModel(
            client: makeClient(body: pending, recorder: RequestRecorder()),
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
        #expect(out?.actions.map(\.title) == ["Refuser : le run continue sans", "Élargir le mandat (Touch ID)"])
        let identifiers = categories.flatMap { $0.actions.map(\.identifier) }
        #expect(identifiers.count == Set(identifiers).count)  // unique across categories
    }
}
