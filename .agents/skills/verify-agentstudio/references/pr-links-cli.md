# J11 — PR links via CLI (draft)

Oracle: `docs/specs/2026-11-09-agent-pr-links/specification.md` R1–R8,
R16–R17 and CLI contract; `verification-design.md` U1, U5, U7 and Fixtures in
the same directory. The route has not been driven on the feature build. Do not
claim a pass until its commands, fixture and readbacks have been exercised there.

## Setup and identity

Use J1 for the declared debug build, matching bundled CLI, isolated code and
owned lifecycle. Record the commit-to-binary receipt, code, data root, PID and
CLI. Create new main pane shells A, B and S; identify their handles and shell
readiness. Use the bundled CLI supplied to each shell, not a PATH lookup.
Establish a real agent binding in A and record its identity; record S's bindings.
The declared worktree fixture is `feat/drawer-browser` / PR #680 while open;
choose one other open PR in this repository and one in another public repo,
checking availability with read-only `gh`. Retain the independent identities.
Missing bindings, fixtures or readback capability make the affected cases UNKNOWN.

For every action retain the exact input, output and a separate exit-code file
written by that pane's shell after the command finishes. Read the file only
after its producer completes. `terminal.send` acceptance and a visible prompt
are not completion evidence. Keep paths in the granted run directory; do not
record credential values.

## Drive and decide

1. From A, add a PR to B using `--target`; list both A and B. B has exactly one
   identity and A's agent as author; A did not acquire it. Repeat the add and
   check the exact already-present line and exit 0, without a duplicate. Exercise
   `--target-env` from the pane whose environment names the intended target.
2. Drive the specification's CLI-table rejection cases with corresponding exit
   files and list readbacks: malformed/non-GitHub input, neither/both targets,
   missing target environment, unknown pane, drawer child, full pane and no
   credential. Check the exact line and exit in the contract; verify no mutation.
   Exercise unreachable only against the owned debug endpoint after confirmed
   retirement. Do not expose or copy credentials to construct a no-credential
   case. If a safe fixture or route is missing, mark that case UNKNOWN.
3. Exercise own removal, another author's refused removal, absent removal and
   re-add; compare the resulting list after each. For multi-author rows, a single
   author's withdrawal preserves the other contribution. Compare list and J12
   for the same pane, including a worktree-only row.
4. For the server-process analogue, mint and retain a fresh UUIDv7 immediately
   before the add. Against only the declared debug data root's `local.sqlite`,
   use a read-only SQLite SELECT count to confirm zero matching S bindings for
   provider `codex` and this conversation ID, including active and ended rows.
   `SessionsRepository+Loading.swift`'s `loadBindingForProviderConversation`
   identifies `sessions_pane_binding` joined to `sessions_conversation` by
   conversation ID and filtered by pane, provider and provider conversation
   ID. Retain the database identity, query, result and status; a failed query is
   not zero. In a background child of S's shell, remove `CLAUDE_CODE_SESSION_ID`
   from that child's environment and set `CODEX_THREAD_ID` to the fresh value, then run
   the bundled `pr add --target` B. The runner checks the Claude variable first;
   leaving it set would exercise a different claim. Retain the child's completion and `.rc`, B's
   list and the popover author. It must say an agent in S, not a provider name,
   S's bound session or an agent in B. `PaneCLICommandRunner` maps that
   environment variable to a writer claim; confirm this mapping and the
   binding readback against the target.
   If the reader cannot establish absence, this case is UNKNOWN. This is not a
   real Router server-agent observation.
5. Record B's list and the data-root identity. Quit the owned debug app by J1;
   verify its retirement, then relaunch the declared build with the same code
   and data root. Confirm the same pane and unchanged list and authors. Close B,
   observe its PRs hidden, Undo and observe the same list restored. Permanent
   purge and its real-time delay need the separate lifecycle proof.

Before and after add/remove, retain A and B's focus, selected pane/tab and
drawer state and `pane.context.get` notice counts. Changes contradict R8.
If the UI or CLI cannot provide an independent readback, report that cell
UNKNOWN rather than treating a command acknowledgement as the outcome.

## Driver gap

J1's `scripts/debug-lifecycle.sh` owns launch and retirement. There is no
validated J11 journey script yet; the pane-origin completion, binding readback
and result collection route must be established on the declared build. Do not
substitute the installed app or another credential. Keep output, `.rc` files,
before/after lists and lifecycle receipts with the run evidence.
