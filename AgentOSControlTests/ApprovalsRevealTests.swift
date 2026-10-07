import AppKit
import SwiftUI
import Testing
@testable import AgentOSControl

/// A click on an approval's notification asks the window for its card. These host the real ApprovalsView
/// over a list longer than the window and check what JT would see: the card on screen, the request spent.
/// (MainView cannot be hosted this way: its `@SceneStorage` drops writes outside a Scene.)
@Suite struct ApprovalsRevealTests {
    private static let count = 40
    private static let farRow = 25  // well below the first screenful (about six rows)

    /// `count` pending approvals; no run attached, so no journal lookup.
    private func client(count: Int = ApprovalsRevealTests.count) -> HostClient {
        let rows = (0..<count).map { i in
            #"{"id":"approval-\#(i)","ts":\#(1_790_000_000 + i),"capability":"file_write","#
                + #""target":"note-\#(i).md","run_id":null,"timeout_at":\#(1_790_000_300 + i)}"#
        }
        let pending = #"{"pending":["# + rows.joined(separator: ",") + "]}"
        return HostClient(
            baseURL: URL(string: "http://127.0.0.1:3107")!, token: { "test-token" },
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(pending.utf8), response)
            })
    }

    @MainActor private func loadedModel(count: Int = ApprovalsRevealTests.count) async -> ControlModel {
        let model = ControlModel(client: client(count: count), presence: .deviceOwner, notifier: nil, socket: nil)
        await model.refreshApprovals()
        return model
    }

    /// Borderless and off screen, like SidebarTests' launch test.
    @MainActor private func host(_ model: ControlModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ApprovalsView().environment(model))
        window.orderFront(nil)
        return window
    }

    @MainActor private func close(_ window: NSWindow) {
        window.close()
        window.contentView = nil
    }

    /// The rows JT can see: the table's visible rectangle, as row indexes (nil until the list exists).
    @MainActor private func visibleRows(in window: NSWindow) -> Range<Int>? {
        guard let table = firstTable(in: window.contentView), table.numberOfRows > 0 else { return nil }
        let range = table.rows(in: table.visibleRect)
        return range.location..<(range.location + range.length)
    }

    private func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
    }

    /// Menu-bar mode: the window did not exist when JT clicked, so the request is set before the list is.
    @MainActor @Test func aRevealAskedBeforeTheListAppearsScrollsToTheCard() async {
        let model = await loadedModel()
        await model.reveal(approvalID: model.openApprovals[Self.farRow].id)
        let window = host(model)
        defer { close(window) }

        #expect(await eventually { model.revealedApprovalID == nil })
        #expect(await eventually { visibleRows(in: window)?.contains(Self.farRow) == true })
    }

    @MainActor @Test func aRevealAskedWhileTheListIsShownScrollsToTheCard() async {
        let model = await loadedModel()
        let window = host(model)
        defer { close(window) }
        #expect(await eventually { visibleRows(in: window)?.contains(0) == true })
        #expect(visibleRows(in: window)?.contains(Self.farRow) == false)  // not there without the click

        await model.reveal(approvalID: model.openApprovals[Self.farRow].id)
        #expect(await eventually { model.revealedApprovalID == nil })
        #expect(await eventually { visibleRows(in: window)?.contains(Self.farRow) == true })
    }

    /// The approval was settled elsewhere before JT clicked: the request is still spent, nothing scrolls.
    @MainActor @Test func aRevealOfAnApprovalThatIsGoneIsSpentAndScrollsNowhere() async {
        let model = await loadedModel()
        let window = host(model)
        defer { close(window) }
        #expect(await eventually { visibleRows(in: window)?.contains(0) == true })

        await model.reveal(approvalID: "approval-already-settled")
        #expect(await eventually { model.revealedApprovalID == nil })
        #expect(visibleRows(in: window)?.contains(0) == true)
    }

    /// No card left to show (the list is the empty placeholder): the request must still be spent, or the
    /// next window to open would jump to Approbations for nothing.
    @MainActor @Test func aRevealWithNoApprovalLeftIsSpent() async {
        let model = await loadedModel(count: 0)
        await model.reveal(approvalID: "approval-already-settled")
        let window = host(model)
        defer { close(window) }

        #expect(await eventually { model.revealedApprovalID == nil })
    }
}
