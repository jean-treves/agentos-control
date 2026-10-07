# AgentOS Control

Menu bar app for macOS that lets a human govern autonomous coding agents run by
AgentOS (JT's governed agent runtime): approve or deny risky tool calls from a notification (approve requires
Touch ID), stop everything with a kill switch, and watch runs, tasks, host health and a live
"floor" of the agents at work, without opening a browser.

## Problem

AgentOS pauses an agent run whenever policy says a human must confirm an action (write a file,
run a shell command). The web cockpit only helps if it is open: approvals expired unanswered and
tripped the circuit breaker (2026-09-21, three cards timed out). The decision has to reach the
human where they are, and the approve path must prove a human is actually there.

## How it works

- `HostClient` (Swift actor) speaks the frozen host-v1 API on `http://127.0.0.1:3107`. Reads are
  unauthenticated; control routes carry the host's bearer token, read from the Keychain through
  `/usr/bin/security` for every action and never logged. No token, no request.
- New approvals are polled every 2 s (the host's WebSocket only announces resolutions and the kill
  switch); each one becomes a notification with Approve and Deny, and clicking the notification
  opens the app on its card.
- Each approval follows a pure state machine: a decision is sent only from the `deciding` state,
  and `approve` reaches it only after Touch ID. Late Touch ID answers, decisions taken elsewhere,
  our own decision echoed by the socket and polls racing a POST are all handled and unit-tested.
- Touch ID also guards the kill switch (both ways) and the breaker reset. Deny needs none.
- A run's detail can open two read-only terminals (Claude, Hermès) on the host's dialogue socket
  (`/ws/runs/{id}/dialogue`). Lines are masked by the host before they are written; the app still strips
  control characters, caps the buffer at 2 000 lines and shows every line as plain text. Scrolling up pauses
  the follow, coming back to the end resumes it. Clocks are this Mac's local time (the host stamps UTC);
  « Copier » puts the whole pane on the pasteboard as plain text; an empty pane says « connexion… » or
  « aucune ligne pour ce run ». The run header counts the run's journal events. Haiku's notes and the arbiter's decisions show as one line
  in the run's timeline.
- Runs ▸ Ménage… lists what Haiku proposes to tidy (worktrees and temp folders of finished runs, and how many
  are kept on purpose); « Appliquer » asks for Touch ID and the host applies the frozen list once (a second apply
  is refused; the first report stays on screen). The two cleanup commands are not in the Commands tab: the list
  must be seen before it is applied.
- Conversation opens a chat with Sonnet per project and mode (read, or modify in a worktree of its own). The
  transcript streams from the host (`/ws/conversations/{id}`), a reply the host cut keeps its « …[+N caractères] »,
  and the header gives the 5 h quota or, after a refusal on another limit (the weekly one), the day and time the
  turn can be sent again; nothing is sent while the quota is spent. The detail is polled every 3 s while Sonnet
  answers and every 15 s otherwise, the list every 30 s.
- The delegation cards Sonnet proposes are edited in place, each with an identity of its own (a poll that shrinks
  the list cannot crash an editor). « Déléguer N tâche(s)… » first shows every card in full, as plain text and
  exactly as the host will seal it, then asks for Touch ID, then makes one host call that creates, seals and
  launches the briefs. The number of the cards that were read (`cards_seq`) goes with the call: cards Sonnet sends
  in the meantime stay in the conversation, and a review left open under new cards is closed. « Promouvoir »
  merges the conversation's worktree; its Touch ID prompt names the project and the conversation.

## Build, test, install

```bash
xcodegen generate
xcodebuild test -project AgentOSControl.xcodeproj -scheme AgentOSControl -destination 'platform=macOS' -derivedDataPath build
Scripts/build_app.sh     # Release, ad hoc signature, /Applications/AgentOS.app (archives the former AgentOS Control.app)
open "/Applications/AgentOS.app" --args -readOnly YES   # optional: observe only, never acts
```

Requirements: macOS 26+, Xcode 26+, XcodeGen. No third-party dependency; ad hoc signing only.

## Results (2026-09-23, macOS 27.0, Xcode 27.0)

| Measure | Value |
|---|---|
| Unit tests (Swift Testing, simulated host, Keychain and Touch ID) | 325 tests in 37 suites, all green (re-run 2026-10-07) |
| Resident memory, installed app with live polling (`ps -o rss=`) | 88.8 MB, flat over 2 minutes (a bare `MenuBarExtra` app measures 81 to 84 MB on the same Mac: shared SwiftUI/AppKit pages) |
| Physical footprint (`footprint`), the app's own memory | 19 MB, flat over 2 minutes |
| End to end (E2E-17, 2026-09-24): governed Claude run asks to run a shell command | notification shown 0.5 s after the request; Approve → Touch ID → decision sent 0.7 s after the click; receipt `decider: human:jean`; the run went on to its next tool call |
