# Pane and terminal operations

This reference owns permitted pane/terminal inspection, exact terminal input and adding drawer children. Start with the caller identity, intended target/effect and any returned sequence/command ID. Return observed runtime state, input receipt or bounded wait result. Stop before an unauthorized mutation or a completion claim that lacks the relevant observation.

## Inspect the actual target

```sh
"$AS_CLI" pane.list --json '{}'
"$AS_CLI" pane.current --json '{}'
"$AS_CLI" pane.snapshot --json '{"handle":"self"}'
"$AS_CLI" terminal.status --json '{"handle":"self"}'
"$AS_CLI" terminal.snapshot --json '{"handle":"self"}'
```

Use inventory/current reads to answer selection questions; use `self` for the caller. A canonical pane UUID or workspace-local `pane:N` ordinal is a supported selector where the method allows it, but possession of a selector does not widen own-pane eligibility.

`terminal.status` reports lifecycle/readiness/backend/capabilities. `terminal.snapshot` reports runtime metadata such as last sequence, timestamp, renderer health, read-only and secure-input state. It contains **no terminal output**. There is no listed terminal capture/output verb. A healthy renderer, title or cwd is not proof that a shell command succeeded.

Good: report runtime readiness and the absence of output evidence. Bad: claim tests passed from `terminal.snapshot`, or invent a capture method to obtain missing text.

## Send exact input only when authorized

```sh
"$AS_CLI" terminal.send --json '{"handle":"self","input":"pwd\n"}'
```

The input is exact text; a trailing newline can execute a shell command. Choose the text for the actual requested task and inspect the target first. The CLI supplies a required correlation ID if omitted; retain the returned pane, command and correlation IDs and `disposition` (`accepted` or `queued`, with any queue position).

Acceptance describes terminal input submission, not shell completion or successful file changes. If delivery is uncertain, inspect relevant state before any new intent; a fresh ID does not make a duplicate input safe. Avoid sending a command merely to discover whether a previous uncertain input ran.

## Observe a bounded condition

```sh
"$AS_CLI" terminal.wait --json '{"handle":"self","condition":"commandFinished","timeoutSeconds":1}'
```

Supported conditions are `attachReady`, `commandFinished`, `rendererHealthy`, `titleChanged`, `cwdChanged` and `progressChanged`. `timeoutSeconds` must be finite and nonnegative; the server can clamp it and returns the effective timeout and `wasClamped`. The CLI's ordinary five-second total budget remains in force, so a requested sixty-second raw wait is not a guaranteed sixty-second observation.

Use `afterSequence` from an actual prior terminal snapshot/event when you need events after that point. The condition/result can include `commandId`, `correlationId`, `exitCode`, duration or health when relevant. Match returned identity to the operation you are claiming. A `commandFinished` event for another command or a title change cannot establish the requested command's exit status.

`timeout` means the condition was not observed within the bounded wait, not that the shell failed. `replayGap` means events after the supplied sequence are no longer retained: read a fresh snapshot and report the missing interval before selecting a new observation. Do not silently claim continuity or invent a generic command-status poll.

## Add a drawer child or close a pane

```sh
"$AS_CLI" drawer.addPane --json '{"parentPaneHandle":"self","content":{"kind":"browser","url":"https://example.com"}}'
"$AS_CLI" drawer.addPane --json '{"parentPaneHandle":"self"}'
```

The first creates the explicitly requested browser child; omitting content creates a terminal child. Replace the example URL with the authorized target. Adding a child neither expands the drawer nor moves focus. Retain returned identities; creation does not grant control over every child pane.

To close an explicitly authorized own pane, use `"$AS_CLI" pane.close --handle self` (or its JSON form). This closes the pane and can affect running work; confirm the actual task permits that effect. A shared worktree diagnostic may print `pane.close <pane-id>`, but the raw method's supported syntax is `--handle`/JSON, and own-pane scope still applies.

`pane.focus`, `pane.split` and `drawer.toggle` are listed but agent-notYetAllowed in the compiled help. Return that boundary rather than using `command.execute` as a bypass. Complete with the actual result/effects and remaining unknowns, not an inferred UI focus or process outcome.
