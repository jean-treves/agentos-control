import Foundation
import os

/// What `/ws/approvals` broadcasts (server/routers/host.py). New approvals are NOT announced there:
/// they are created by another process, so the app polls `GET /api/approvals/pending` for them.
nonisolated enum SocketMessage: Equatable, Sendable {
    case approvalResolved(id: String, approved: Bool)
    case killSwitch(Bool)

    private struct Wire: Decodable {
        let type: String
        let id: String?
        let decision: String?
        let state: Bool?
    }

    static func parse(_ text: String) -> SocketMessage? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)) else { return nil }
        switch (wire.type, wire.id, wire.decision, wire.state) {
        case ("approval_resolved", let id?, "approve", _): return .approvalResolved(id: id, approved: true)
        case ("approval_resolved", let id?, "deny", _): return .approvalResolved(id: id, approved: false)
        case ("killswitch", _, _, let state?): return .killSwitch(state)
        default: return nil
        }
    }
}

/// Unauthenticated listener on `/ws/approvals`; reconnects every 5 s while the host is down.
/// Missed messages are harmless: the 2 s poll reconciles approvals and the kill switch anyway.
nonisolated final class ApprovalsSocket: Sendable {
    private let url: URL
    private let logger = Logger(subsystem: "com.jeantreves.agentoscontrol", category: "socket")

    init(baseURL: URL) { url = Self.socketURL(for: baseURL) }

    static func socketURL(for baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/approvals"
        return components.url!
    }

    func messages() -> AsyncStream<SocketMessage> {
        AsyncStream { continuation in
            let loop = Task {
                while !Task.isCancelled {
                    await receiveUntilClosed(continuation)
                    try? await Task.sleep(for: .seconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in loop.cancel() }
        }
    }

    private func receiveUntilClosed(_ continuation: AsyncStream<SocketMessage>.Continuation) async {
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        await withTaskCancellationHandler {
            do {
                while true {
                    if case .string(let text) = try await socket.receive(), let message = SocketMessage.parse(text) {
                        continuation.yield(message)
                    }
                }
            } catch {
                logger.info("socket closed: \(error.localizedDescription, privacy: .public)")
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}
