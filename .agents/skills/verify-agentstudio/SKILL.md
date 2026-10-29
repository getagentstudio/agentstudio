---
name: verify-agentstudio
description: "Use when verifying a declared Agent Studio debug build's pane context: sidebar, drawer toolbar, ⌘R card, Messages and Agent Line popovers, displayed-agent status, credential warnings, or terminal lifecycle/restore. Includes source-backed scenario setup and native capture; not product repair, builds, performance acceptance or releases."
---

# Verify Agent Studio

Observe the declared debug build through the user's real surface. A setup
receipt, IPC acknowledgement and painted outcome are different evidence.
Take expected values from the adopted source; compare each consumer to those
facts, not merely to the other consumers. Return PASS/FAIL/UNKNOWN per observation.
NOT RUN, blocked, invalid timing and missing fixtures are UNKNOWN reasons.
An independently observed failure wins over an UNKNOWN sub-observation.

## Target, readiness and grant

1. Confirm source worktree/branch/HEAD, prepared and bundled executable provenance,
   matching compiled CLI and debug code from the Lead's declaration. Equal source
   does not attest an installed binary. Use J1's launch/readiness/health procedure
   only when launched under that grant; upkeep/self-tests never launch an app.
2. Keep one declared debug code under `com.agentstudio.app.debug`, with isolated data/zmx/IPC
   roots. Own PID/start/window/panes and sole operator/capture/cleanup roles before
   driving. Refuse stable/beta, unowned target, changed pin or permission prompt.
   Never `pkill AgentStudio`, unlock the screen or change TCC/transport to bypass
   denial. Process inspection errors are not absence; launcher `pgrep || true`
   can swallow denial. Operate only a process launched here or explicitly handed over.
3. Canonical skill is `.agents/skills/verify-agentstudio/`; Claude is only its
   relative link. Keep runtime evidence outside the skill in the granted run
   directory. These recipes grant neither app writes nor fixture installation.
4. For J4–J10 load `references/pane-proof-setup.md` and `references/pane-contract.md`;
   return provenance, ownership, health and fixture/access gaps. For pane-context
   r5 load `references/pane-context-scenarios.md` and its adopted spec/checklist.
   For every visual journey load `references/visual-quality.md` and return actual
   widths, opened originals and independent functional/taste verdicts.

## Journey index

| Journey | Required procedure and real entry | Deciding observation / driver |
| --- | --- | --- |
| J1 — isolated lifecycle | `references/debug-launch.md`; declared background debug launcher, authenticated readiness/health and owned quit | Correct process/build/root, pane/window readbacks, confirmed owned PID retirement. `scripts/debug-lifecycle.sh`. |
| J2 — Panes row motion | `references/panes-row.md`; declared real compatible provider/CLI stimulus | Working glyph breathes, monitoring rotates, others still; chip never pulses, Reduce Motion stops it, branch/recency correct. Legacy stateful-line stimulus requires old applicability. `scripts/panes-row.sh`, `frame_diff.py`. |
| J3 — cold restore | `references/cold-restore.md`; explicit owned single-session fault grant | Same pane/stored session, restore notice → saved text → restart marker → usable new shell (Spec 13 / Program Design 28 item 2; foreground material superseded). Warm reconnect insufficient. `scripts/cold-restore.sh`. |
| J4 — drawer toolbar | `references/drawer-toolbar.md`; real pane-origin line/notice/ask plus actual chip interaction | One line, notes divider, all chips XOR Agent Line XOR empty, complete bracketed line age, no status/warning; fixed groups/height. `scripts/window-frame.sh`, `toolbar_geometry.py`, `pane-chrome.sh`. |
| J5 — ⌘R card | `references/pane-card.md`; select pane/open actual management layer, real request/service actions | Correct status/line/request/unread/ACTIVE, no recency/play chips; exact selected ask/receipt/rebind, conditional metadata/copy and independent clocks. `scripts/window-frame.sh`, `pane-chrome.sh`. |
| J6 — credential warning | `references/credential-warning.md`; genuine owned protected refusal | Quiet success neither creates nor clears refusal; current warning card-only, no toolbar/sidebar warning. `scripts/window-frame.sh`. |
| J7 — agent in displaying pane | `references/agent-setups.md`; actual contained foreground, remote app-server, Claude daemon/attach and Cursor turns | That pane's actual status/title/line, actual hook recipient and N-of-4 coverage. Standalone remote label includes Router wrapper not exercised. Provider operator plus `window-frame.sh`/native capture. |
| J8 — sidebar context | `references/sidebar-context.md`; actual row, chip and line entries | Title/status/line/chips stack, all kind counts, evidence gate, S11 actual 260pt, real navigation. `scripts/window-frame.sh`, `pane-chrome.sh`. |
| J9 — Messages | `references/messages-popover.md`; press actual row/toolbar chip or card link | Actual native popover, full groups/body/explanation/source/actions, state/receipt control absence, footer and final scroll content. `scripts/pane-chrome.sh inventory/capture`. |
| J10 — Agent Line popover | `references/agent-line-popover.md`; press actual sidebar line | Full text/bracketed age/writer/refs/Go to pane; no E7; real focus destination. `scripts/pane-chrome.sh inventory/capture`. |

Each indexed script is the single implementation at the existing skill-local
scripts home; the references do not copy it. Scripts collect one step at a time.
Exit 0 is collection/setup, never a journey verdict or feature acceptance.

## Scenario setup and known real-target gaps

`references/pane-context-scenarios.md` owns S1–S19 recipes, four evidence states,
drawers, form/location matrix, held receipts/lifecycle, old line, oversubscribed
card, prompt-only refresh and action destinations. The input helper prints
synthetic JSON for the **real adapter**; it never sends or establishes binding.
The offline helper makes a new closed-database copy; it never installs or launches.

G07/G08: real ingress cannot produce approval-with-summary or exact S18 two-listed/
one-omitted. The assigned proof is labelled synthetic product tests; cite their
actual receipt only once available. Native cells remain UNKNOWN/real ingress
unavailable. Never alter mapping/limit or relabel a question to fill them.

Updated recipes are **draft for live coverage until driven on a declared target**.
Self-tests cover apparatus only. Under Program Design r5, flat notice rows have
no UI read trigger: notices remain unread/countable until dismissed. Read-notice
scenes (including S19's read failure) use product-test-only fixtures and remain
a named live setup gap. Never invent disclosure/expand-to-read or a replacement
Mark read action. Unavailable eligible hook, offline datastore load, fault/failure
or opener fixtures leave their specific journey cases UNKNOWN too.

## Driver help and self-tests

Run from repository root. Every runtime command needs its separate grant.

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/panes-row.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/pane-chrome.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/pane-context-input.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/offline-pane-line.sh --self-test
uv run --offline --with pillow --with numpy python -I .agents/skills/verify-agentstudio/scripts/frame_diff.py --self-test
uv run --offline --with pillow --with numpy python -I .agents/skills/verify-agentstudio/scripts/toolbar_geometry.py --self-test
```

Use each driver's `--help` before a live command. Tests use only private stubs or
owned temporary fixtures; no app, real escrow, native capture or network call.
The Python tools need their declared packages; dependency setup/cache access is
separate from product observation. Do not install anything as a self-test fallback.

## Evidence, captures and cleanup

J1 binds readiness to the exact launched incarnation. `health` retains successful
`pane.list`/`window.list` and actual terminal readiness; port/process existence
alone is insufficient. `terminal.snapshot` is lifecycle metadata, not terminal
output; `terminal.send` only accepts input. Use correlated child/owner completion.

For static content-view layout/text, `window-frame.sh` checks ownership, observes
3s after owner-state completion, records optional same-pane `session.query` and
captures **once**, preserving request/result, timestamps/lock probes and immutable
PNG transfer receipts. A stale/in-flight/blank frame after settle fails; no longer
wait/retry/reopen repairs it. Metadata only locates crops; open the original PNG.

Popover, final native appearance, motion, tooltips and pasteboard require their
own already-unlocked granted route. `pane-chrome.sh inventory` retains local
PID-window inventory; capture the actual popover window or an original visibly
including it. Main-window pixels without the popover prove none of it. Do not
infer content from AX full strings, window-array order or the image filename.

Keep commands/statuses/stderr, provenance and state/readback facts, measured
applied/window/surface widths, originals/crop origins, capture owner and per-state
R1–R10/quality judgments in the run directory. Distinguish synthetic producer
stimuli, synthetic product tests and real app observations. Preserve failures and
UNKNOWN cells; no equivalent rerun without change or an unresolved concern.

Post denied-command evidence only to the assigned trace destination, or return
it to the Lead when none is granted. Missing/unattempted access is distinct from
denial. No new board authority follows from the recipe.

`window-frame.sh cleanup RUN_DIR` resumes only recorded transfers, even after
retirement; preserve unresolved source paths. It grants no app quit. Quit only
an owned debug bundle through J1 and confirm PID retirement; never sweep pane
records, snapshots or render directories. Keep any held fixture's owner named.

Return per-observation PASS/FAIL/UNKNOWN with commit/binary/CLI, PID/window/pane,
state/originals/measurements, required live gaps and retained evidence. Product
suite, CI, performance, release and acceptance remain their own proof layers.
