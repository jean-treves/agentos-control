import Foundation
import Testing
@testable import AgentOSControl

/// The Keychain is simulated: no test ever runs /usr/bin/security.
actor CommandLog {
    private(set) var calls: [[String]] = []
    func record(_ call: [String]) { calls.append(call) }
}

func simulatedToken(status: Int32, output: String, log: CommandLog? = nil) -> ControlToken {
    ControlToken { executable, arguments in
        await log?.record([executable] + arguments)
        return CommandResult(status: status, output: Data(output.utf8))
    }
}

@Suite struct ControlTokenTests {
    @Test func readsAndTrimsTheTokenWithTheHostsCommand() async throws {
        let log = CommandLog()
        let token = try await simulatedToken(status: 0, output: "s3cr3t-value\n", log: log).read()
        #expect(token == "s3cr3t-value")
        #expect(await log.calls == [[
            "/usr/bin/security", "find-generic-password", "-s", "agentos-control", "-a", "agentos", "-w",
        ]])
    }

    @Test func missingItemIsNil() async throws {
        #expect(try await simulatedToken(status: 44, output: "").read() == nil)
    }

    @Test func emptyValueIsNil() async throws {
        #expect(try await simulatedToken(status: 0, output: " \n").read() == nil)
    }

    @Test func otherExitStatusIsATypedError() async {
        await #expect(throws: ControlTokenError.securityFailed(51)) {
            _ = try await simulatedToken(status: 51, output: "").read()
        }
    }

    @Test func launchFailureIsATypedError() async {
        let broken = ControlToken { _, _ in throw CocoaError(.fileNoSuchFile) }
        let error = await #expect(throws: ControlTokenError.self) { _ = try await broken.read() }
        guard case .launchFailed = error else {
            Issue.record("expected .launchFailed, got \(String(describing: error))")
            return
        }
    }

    /// Exercises the real Process plumbing on a harmless command, never on the Keychain.
    @Test func systemRunnerCapturesStdoutAndStatus() async throws {
        let result = try await ControlToken.systemRunner("/bin/sh", ["-c", "printf abc; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.output, as: UTF8.self) == "abc")
    }
}
