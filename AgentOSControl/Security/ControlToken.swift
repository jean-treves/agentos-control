import Foundation

nonisolated struct CommandResult: Sendable, Equatable {
    let status: Int32
    let output: Data
}

nonisolated enum ControlTokenError: Error, Equatable, Sendable {
    case launchFailed(String)
    case securityFailed(Int32)
}

/// Reads the host's control token (Keychain item `agentos-control` / `agentos`) the way the host
/// does (kernel/keychain.py): through `/usr/bin/security`, which is already in the item's ACL.
/// SecItemCopyMatching would prompt for the login password, and an ad hoc "Always Allow" is tied
/// to the cdhash, so lost at every rebuild (macos-app-facts.md). The value is never logged.
nonisolated struct ControlToken: Sendable {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> CommandResult

    /// `security` exit status for errSecItemNotFound.
    static let itemNotFound: Int32 = 44

    private let run: Runner

    init(run: @escaping Runner = ControlToken.systemRunner) { self.run = run }

    /// The token, or nil when the item is absent or empty.
    func read() async throws(ControlTokenError) -> String? {
        let result: CommandResult
        do {
            result = try await run(
                "/usr/bin/security",
                ["find-generic-password", "-s", "agentos-control", "-a", "agentos", "-w"])
        } catch {
            throw .launchFailed(String(describing: error))
        }
        switch result.status {
        case 0:
            let token = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        case Self.itemNotFound:
            return nil
        default:
            throw .securityFailed(result.status)
        }
    }

    /// ponytail: stdout is read after exit, fine for a token-sized output (pipe buffer is 64 KB).
    static let systemRunner: Runner = { executable, arguments in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CommandResult(status: finished.terminationStatus, output: output))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
