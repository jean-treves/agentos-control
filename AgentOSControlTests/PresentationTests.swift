import Foundation
import Testing
@testable import AgentOSControl

/// Synthetic journal of one Claude run: shapes from the live journal, values invented.
private let runJournal = """
{"events":[
  {"v":1,"seq":100,"ts":"2026-09-23T21:00:00.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":null,"type":"health","data":{"detail":"ok","paused":"no","preflight":"ok"},
   "prev_hash":"a","hash":"b"},
  {"v":1,"seq":101,"ts":"2026-09-23T21:00:01.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":"claude","type":"run.started","data":{"argv0":"claude","cwd":"/tmp/x"},
   "prev_hash":"b","hash":"c"},
  {"v":1,"seq":102,"ts":"2026-09-23T21:00:02.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":"claude","type":"tool.requested","data":{"tool":"Read","input_excerpt":"notes.md"},
   "prev_hash":"c","hash":"d"},
  {"v":1,"seq":103,"ts":"2026-09-23T21:00:03.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":"claude","type":"decision","data":{"verdict":"allow","tool":"Read",
   "capability":"file_read","decider":"policy","rule":"explore.read"},"prev_hash":"d","hash":"e"},
  {"v":1,"seq":104,"ts":"2026-09-23T21:00:04.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":"claude","type":"tool.requested","data":{"tool":"Edit","input_excerpt":"README.md"},
   "prev_hash":"e","hash":"f"},
  {"v":1,"seq":105,"ts":"2026-09-23T21:00:05.000Z","run_id":"run_0123456789abcdef0123456789abcdef",
   "task_id":"t_0a1b2c3d4e","engine":"claude","type":"approval.resolved","data":{"approval_id":"x",
   "approved":true,"decider":"human:jean","waited_ms":900},"prev_hash":"f","hash":"g"}]}
"""

private struct Page: Decodable { let events: [JournalEvent] }

private func events() throws -> [JournalEvent] {
    try JSONDecoder.host.decode(Page.self, from: Data(runJournal.utf8)).events
}

private func run(source: String?) -> RunSummary {
    RunSummary(runId: "run_0123456789abcdef0123456789abcdef", prompt: "p", source: source, status: "running",
               createdAt: 1_790_000_000, updatedAt: nil)
}

@Suite struct PresentationTests {
    @Test func foldsEngineLastToolAndToolCalls() throws {
        let activity = RunActivity().folding(try events())
        #expect(activity.engine == "claude")
        #expect(activity.lastTool == "Edit")
        #expect(activity.toolCalls == 2)
        #expect(activity.lastSeq == 105)
    }

    @Test func foldingIsIncrementalAndIdempotent() throws {
        let all = try events()
        let once = RunActivity().folding(all)
        let inTwo = RunActivity().folding(Array(all.prefix(3))).folding(Array(all.dropFirst(3)))
        #expect(inTwo == once)
        #expect(once.folding(all) == once)
    }

    @Test func toolCallLimitPrefersTheTaskBudget() throws {
        let tasks = try JSONDecoder.host.decode(TaskPage.self, from: Data(Fixture.tasks.utf8)).tasks
        #expect(RunActivity.toolCallLimit(for: run(source: "task:t_0a1b2c3d4e"), tasks: tasks) == 3)
        #expect(RunActivity.toolCallLimit(for: run(source: "task:v_0123456789ab"), tasks: tasks) == 60)
        #expect(RunActivity.toolCallLimit(for: run(source: "schedule"), tasks: tasks) == 60)
        #expect(RunActivity.toolCallLimit(for: run(source: nil), tasks: []) == 60)
    }

    @Test func remainingBudgetNeverGoesNegative() throws {
        let activity = RunActivity().folding(try events())
        #expect(activity.remainingToolCalls(limit: 60) == 58)
        #expect(activity.remainingToolCalls(limit: 1) == 0)
    }

    @Test func journalLinesAreReadable() throws {
        let lines = try events().map(\.summary)
        #expect(lines == ["", "", "Read · notes.md", "allow · Read · policy · explore.read", "Edit · README.md",
                          "approuvé par human:jean"])
    }

    @Test(arguments: [
        ("paused", [TaskAction.resume, .cancel]),
        ("queued", [.pause, .cancel]),
        ("deferred", [.pause, .cancel]),
        ("running", []),
        ("done", []),
        ("cancelled", []),
    ])
    func taskActionsFollowTheStatus(status: String, expected: [TaskAction]) {
        #expect(TaskAction.available(for: status) == expected)
    }

    @Test func newTaskNeedsATitleAndAPrompt() {
        var draft = NewTask(title: "  ", prompt: "Do it", project: "", engine: "claude", profile: "explore")
        #expect(!draft.isSubmittable)
        draft.title = "Sample"
        #expect(draft.isSubmittable)
        draft.prompt = "\n"
        #expect(!draft.isSubmittable)
    }
}

private struct TaskPage: Decodable { let tasks: [AgentTask] }
