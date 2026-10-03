import Foundation
import Testing
@testable import AgentOSControl

@Suite struct CommandFormTests {
    let spec = CommandSpec(
        name: "drawback", title: "Drawback", description: "d", interactive: false,
        params: [
            CommandParam(name: "session", label: "Conversation", kind: "choice", choices: ["s1", "s2"],
                         defaultValue: nil, required: true),
            CommandParam(name: "profile", label: "Profil", kind: "choice", choices: ["explore", "trusted"],
                         defaultValue: "explore", required: true),
            CommandParam(name: "note", label: "Note", kind: "text", choices: nil, defaultValue: nil, required: false),
            CommandParam(name: "at", label: "Quand", kind: "datetime", choices: nil,
                         defaultValue: "2026-09-28T19:43:00Z", required: true),
        ])

    @Test func defaultsTakeTheServerDefaultThenTheFirstChoice() {
        #expect(CommandForm.defaults(spec) == ["session": "s1", "profile": "explore"])
        #expect(CommandForm.defaultDates(spec)["at"] == ISO8601DateFormatter().date(from: "2026-09-28T19:43:00Z"))
    }

    @Test func payloadDropsEmptyTextAndSendsDatesInISO() {
        let at = ISO8601DateFormatter().date(from: "2026-09-29T02:03:04Z")!
        let payload = CommandForm.payload(spec, values: ["session": "s2", "profile": "trusted", "note": ""],
                                          dates: ["at": at])
        #expect(payload == ["session": "s2", "profile": "trusted", "at": "2026-09-29T02:03:04Z"])
    }

    @Test func requiredTextMustBeFilled() {
        #expect(CommandForm.isComplete(spec, values: ["session": "s1", "profile": "explore"]))
        #expect(!CommandForm.isComplete(spec, values: ["profile": "explore"]))
    }

    /// Python's `isoformat()` may carry microseconds or no offset: a missed default would silently
    /// turn a scheduled launch into « now ».
    @Test func defaultDateAcceptsPythonIsoVariants() {
        let utc = ISO8601DateFormatter().date(from: "2026-09-28T19:43:00Z")!
        #expect(CommandForm.parseISO("2026-09-28T19:43:00+00:00") == utc)
        #expect(CommandForm.parseISO("2026-09-28T19:43:00.250000+00:00") == utc.addingTimeInterval(0.25))
        #expect(CommandForm.parseISO("2026-09-28T19:43:00Z") == utc)
        #expect(CommandForm.parseISO("2026-09-28T19:43:00") != nil)
        #expect(CommandForm.parseISO("demain") == nil)
    }

    /// The host reads a naive date as UTC (`replace(tzinfo=UTC)`): reading it as this Mac's local time
    /// would shift a scheduled launch by the offset (2 h in Paris) without JT seeing it.
    @Test func aDateWithoutTimeZoneIsUTC() {
        let utc = ISO8601DateFormatter().date(from: "2026-09-28T19:43:00Z")!
        #expect(CommandForm.parseISO("2026-09-28T19:43:00") == utc)
        #expect(CommandForm.parseISO("2026-09-28T19:43:00.250000") == utc.addingTimeInterval(0.25))
        #expect(CommandForm.parseISO("2026-09-28T19:43:00+02:00") == utc.addingTimeInterval(-2 * 3600))
        let naiveDefault = CommandSpec(
            name: "x", title: "X", description: "d", interactive: false,
            params: [CommandParam(name: "at", label: "Quand", kind: "datetime", choices: nil,
                                  defaultValue: "2026-09-28T19:43:00", required: true)])
        #expect(CommandForm.payload(naiveDefault, values: [:], dates: CommandForm.defaultDates(naiveDefault))
                == ["at": "2026-09-28T19:43:00Z"])
    }

    @Test func anOptionalDateStaysUnsentUntilPicked() {
        let optional = CommandSpec(
            name: "x", title: "X", description: "d", interactive: false,
            params: [CommandParam(name: "until", label: "Jusqu'à", kind: "datetime", choices: nil,
                                  defaultValue: nil, required: false)])
        #expect(CommandForm.defaultDates(optional).isEmpty)
        #expect(CommandForm.payload(optional, values: [:], dates: [:]).isEmpty)
        let picked = ISO8601DateFormatter().date(from: "2026-10-02T08:00:00Z")!
        #expect(CommandForm.payload(optional, values: [:], dates: ["until": picked]) == ["until": "2026-10-02T08:00:00Z"])
    }

    @Test func aRequiredDateWithoutDefaultStartsAtNow() {
        let required = CommandSpec(
            name: "x", title: "X", description: "d", interactive: false,
            params: [CommandParam(name: "at", label: "Quand", kind: "datetime", choices: nil,
                                  defaultValue: nil, required: true)])
        #expect(CommandForm.defaultDates(required)["at"] != nil)
    }

    @Test func summaryNamesRunsScheduledTasksAndImmediateResults() {
        #expect(CommandsView.summary(CommandLaunch(command: "passover", taskIds: ["t_1"], runIds: ["0f0e0d0c-aaaa"], result: nil))
                == "passover : run 0f0e0d0c lancé")
        #expect(CommandsView.summary(CommandLaunch(command: "passover", taskIds: ["t_1", "t_2"], runIds: [], result: nil))
                == "passover : programmée (t_1, t_2)")
        #expect(CommandsView.summary(CommandLaunch(command: "promote", taskIds: [], runIds: [], result: ["branch": "b", "sha": "abc"]))
                == "promote : branch b, sha abc")
    }

    /// F2: « Ménage : appliquer » in the generic form preselected the first open proposal, one JT never saw.
    /// The two cleanup commands are reached from Runs ▸ Ménage… only, where the list is shown first.
    @Test func cleanupCommandsAreNotInTheGenericList() {
        let specs = ["optimisation", "menage", "passover", "menage-appliquer", "pitch"].map {
            CommandSpec(name: $0, title: $0, description: "d", interactive: false, params: [])
        }
        #expect(CommandsView.listed(specs).map(\.name) == ["optimisation", "passover", "pitch"])
        #expect(CommandsView.listed([]).isEmpty)
    }

    /// F1: a command that takes long asks for its own timeout through the model, the path every sheet uses.
    @MainActor @Test func aSlowCommandAsksForItsOwnTimeout() async {
        let recorder = RequestRecorder()
        let model = ControlModel(
            client: makeClient(body: #"{"command":"drawback","task_ids":[],"run_ids":[],"result":null}"#, recorder: recorder),
            presence: HumanPresence { _ in true }, notifier: nil, socket: nil)
        _ = await model.runCommand(spec, params: [:])
        _ = await model.runCommand(spec, params: [:], timeout: HostClient.slowCommandTimeout)
        #expect(await recorder.requests.map(\.timeoutInterval) == [60, HostClient.slowCommandTimeout])
    }

    @MainActor @Test func runCommandWithoutPresenceSendsNothing() async {
        let recorder = RequestRecorder()
        let model = ControlModel(client: makeClient(recorder: recorder),
                                 presence: HumanPresence { _ in false }, notifier: nil, socket: nil)
        #expect(await model.runCommand(spec, params: [:]) == nil)
        #expect(await recorder.requests.isEmpty)
        // The sheet shows this sentence: a silent nil would leave JT with a form that does nothing.
        #expect(model.failureReason == ControlModel.notConfirmed)
    }

    @MainActor @Test func aRefusedLaunchGivesTheSheetTheHostsReason() async {
        let model = ControlModel(
            client: makeClient(status: 400, body: #"{"detail":"Brief : valeur hors liste"}"#, recorder: RequestRecorder()),
            presence: HumanPresence { _ in true }, notifier: nil, socket: nil)
        #expect(await model.runCommand(spec, params: [:]) == nil)
        #expect(model.failureReason == "Refusé par le host : Brief : valeur hors liste")
    }

    @MainActor @Test func theTouchIDPromptNamesTheBriefBeingLaunched() async {
        let reasons = ReasonRecorder()
        let model = ControlModel(client: makeClient(recorder: RequestRecorder()),
                                 presence: HumanPresence { reason in await reasons.add(reason); return false },
                                 notifier: nil, socket: nil)
        let passover = CommandSpec(name: "passover", title: "Passover", description: "d", interactive: false, params: [])
        _ = await model.runCommand(passover, params: ["brief": "2026-09-29-dm.md"])
        _ = await model.runCommand(passover, params: [:])
        #expect(await reasons.values == ["lancer « Passover » sur « 2026-09-29-dm.md »", "lancer « Passover »"])
    }
}

actor ReasonRecorder {
    private(set) var values: [String] = []
    func add(_ reason: String) { values.append(reason) }
}
