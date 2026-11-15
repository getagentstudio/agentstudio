# Caller pane and session context

This reference owns reading the caller pane, its current drawers and hook-owned session summary. Start with supplied runtime identity and the question the context must answer. Return relevant state, exact continuation cursors and any remaining truncation. Stop when the requested view is complete or the refused/unreachable page is named as a gap.

```sh
"$AS_CLI" pane
"$AS_CLI" pane.snapshot --json '{"handle":"self"}'
"$AS_CLI" session.query --json '{"handle":"self"}'
```

`pane` reads the first composed context page for the credential pane. It can contain Agent Title/Line, session summary, messages, current drawer messages, links/pull-request state and truncation. Missing/unknown state is not an empty verified result. `session.query` reads the current status-engine session summary; it is not a command to establish tracking or change status.

`pane.snapshot` reads one explicit pane and workspace context. `pane.current`, `window.current` and `workspace.current` concern current UI selection, not a stable assertion about the caller. Read-only inventory can help identify a requested target, but an own-pane method remains scoped to the credential pane even if another pane's UUID is known.

## Retrieve omitted context

```sh
"$AS_CLI" pane.context.get --json '{"handle":"self","page":{"kind":"first"}}'
```

The result has a composed 1 MiB logical budget and transport bounds. Read `truncation` before claiming all live messages were inspected:

- Each `truncation.omitted` row names `source`, counts of omitted open asks/unread notices, and `next` with `rank`/`position`.
- For that row, request `page: {"kind":"more","source":SOURCE_UUID,"after":RETURNED_NEXT}`. SOURCE_UUID and RETURNED_NEXT stand for the exact returned UUID and cursor object in valid JSON, not quoted placeholder text.
- `remainingLiveSources` and `nextSourcesAfter` describe source groups beyond the represented set. Request `page: {"kind":"moreSources","after":RETURNED_SOURCE_UUID}` with that returned UUID.
- Inspect each new page's truncation and retain any still-needed continuation. Copy cursors exactly; never increment positions, make up a rank or substitute a pane ordinal for a source UUID.

Use JSON/stdin for these nested page objects. A drawer group identifies its source with `sourcePaneId`; reading its messages through the composed context does not authorize controlling that child's terminal. If the live drawer set changes, a continuation can return `sourceNotInView`; reread the first page and report any continuity gap instead of claiming an uninterrupted history.

Good: follow omitted rows and additional-source cursors until the requested live context has no relevant truncation. Bad: treat `pane`'s first page as all history, or use a terminal snapshot as missing message/output text.

## Status is observation

Harness hooks record lifecycle and refusal information; this read does not create a session binding. Keep the supplied provider identity and distinguish a connection/refusal warning from current work status. Never synthesize `session.event`, `session.status` or `session.refusal` to make the display match an inferred result.

Retain the result's `paneId` and `revision` when reporting what was inspected. A read receipt establishes that view, not completed terminal work, delivered messages or approval. If authentication or a required page fails, report the exact missing view and continue only work that does not depend on it.
