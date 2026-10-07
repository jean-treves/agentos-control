import os
import UserNotifications

/// What ControlModel needs from Notification Center (a stub in tests).
protocol ApprovalNotifying: AnyObject {
    var onAction: ((_ approvalID: String, _ approve: Bool) async -> Void)? { get set }
    /// A click on the banner itself, not on one of its buttons.
    var onOpen: ((_ approvalID: String) async -> Void)? { get set }
    func install()
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func post(_ approval: Approval, context: ApprovalContext?) async
    func withdraw(_ approvalIDs: [String])
}

/// One notification per pending approval (identifier = approval id), category `APPROVAL` with
/// `APPROVE` and `DENY`. The delegate is mandatory: without it macOS hides banners while the app
/// is frontmost and never reports the chosen action (macos-app-facts.md).
final class ApprovalNotifier: NSObject, UNUserNotificationCenterDelegate, ApprovalNotifying {
    nonisolated static let categoryID = "APPROVAL"
    nonisolated static let approveID = "APPROVE"
    nonisolated static let denyID = "DENY"

    /// What a click on a notification asks for: its buttons decide, its body opens the app on the card.
    enum Route { case approve, deny, open, ignore }

    nonisolated static func route(_ actionIdentifier: String) -> Route {
        switch actionIdentifier {
        case Self.approveID: .approve
        case Self.denyID: .deny
        case UNNotificationDefaultActionIdentifier: .open
        default: .ignore
        }
    }

    /// Set by ControlModel: runs the same Touch ID → decision path as the window.
    var onAction: ((_ approvalID: String, _ approve: Bool) async -> Void)?
    /// Set by ControlModel: brings the window up on the approval's card.
    var onOpen: ((_ approvalID: String) async -> Void)?
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "notifications")

    /// Call at launch, before any notification can be answered.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // `.authenticationRequired` is ignored on macOS; kept for intent, Touch ID happens in the app.
        let approve = UNNotificationAction(
            identifier: Self.approveID, title: "Approuver (Touch ID)", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyID, title: "Refuser", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [approve, deny], intentIdentifiers: [])
        ])
    }

    /// Asks once; a prompt swiped away counts as denied, hence the menu bar hint.
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                logger.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return await isAuthorized()
    }

    func isAuthorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    func post(_ approval: Approval, context: ApprovalContext?) async {
        let content = UNMutableNotificationContent()
        content.title = "Approbation : \(approval.capability ?? "outil inconnu")"
        content.subtitle = context?.summary ?? ""
        content.body = String((approval.target ?? "").prefix(120))
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: approval.id, content: content, trigger: nil))
        } catch {
            logger.error("notification not posted: \(error.localizedDescription, privacy: .public)")
        }
    }

    func withdraw(_ approvalIDs: [String]) {
        guard !approvalIDs.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: approvalIDs)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let approvalID = response.notification.request.identifier
        switch Self.route(response.actionIdentifier) {
        case .approve: await deliver(approvalID: approvalID, approve: true)
        case .deny: await deliver(approvalID: approvalID, approve: false)
        case .open: await deliverOpen(approvalID: approvalID)
        case .ignore: break
        }
    }

    private func deliver(approvalID: String, approve: Bool) async {
        logger.notice("notification action \(approve ? "APPROVE" : "DENY", privacy: .public) on \(approvalID, privacy: .public)")
        await onAction?(approvalID, approve)
    }

    private func deliverOpen(approvalID: String) async {
        logger.notice("notification opened on \(approvalID, privacy: .public)")
        await onOpen?(approvalID)
    }
}
