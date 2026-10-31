# Source register and proof limits

This register preserves the substantive findings, source versions and experiment
boundaries behind the two reports. Source snapshots are historical evidence;
they are not a claim that later main-branch code still has the same behavior.

## UI track

The AgentStudio UI source walkthrough used commit
[`2fa2b16d671026fefbe9f79c7f8304c4f295afd5`](https://github.com/getagentstudio/agentstudio/tree/2fa2b16d671026fefbe9f79c7f8304c4f295afd5).
The report links directly to the files at that commit. It identified two
geometry-sync entry paths, retained native pane hosts, existing equality guards,
and popover geometry-to-state-to-frame feedback. Actual per-interaction counts
and costs were not measured by this investigation.

The bundled Ghostty source pin was
[`2fb0c9cacb3fc75dbc8aedee9b7ed4321f091d33`](https://github.com/ghostty-org/ghostty/tree/2fb0c9cacb3fc75dbc8aedee9b7ed4321f091d33).
The Messages timing table was supplied from a separate-host verifier run; its
raw profile and exact binary were not independently identified here. Overlapping
profile categories must not be added, and the older workload is not a valid
before/after comparator.

### First-party development descriptions

- [June 25 split prototype](https://x.com/mitchellh/status/2070273858154987537):
  SwiftUI and Core Animation development work, with placeholder panes.
- [June 25 layout explanation](https://x.com/mitchellh/status/2070281069631611056):
  logical split tree, flat displayed rectangles, full-size incoming pane and
  slide/occlusion treatment. The video visibly shows the existing pane narrowing.
- [June 29 native hosting](https://x.com/mitchellh/status/2071657456854605869):
  SwiftUI-provided content coordinated through native hosting.
- [August 4 product demonstration](https://x.com/mitchellh/status/2084630173954326672):
  names the SuperSplit and SuperTabs kits in the Superlogical demonstration.
- [August 12 tab peek](https://x.com/mitchellh/status/2087537750182666290):
  live Metal previews; the main terminal is described as retaining its dimensions.
  This does not specify native view parenting or texture reuse.
- [July 2 renderer](https://x.com/mitchellh/status/2072724957902381319) and
  [layer separation](https://x.com/mitchellh/status/2072727030345748759):
  developer-described emulation, rendering and terminal layers.
- [August 30 frame preparation](https://x.com/mitchellh/status/2094105577979019726):
  preparing non-MainActor-required work before the UI frame. This is not an
  executor or latency measurement of the installed app.

The offscreen-rendering post at
[`2088390469248254291`](https://x.com/mitchellh/status/2088390469248254291)
was retrieved with a visibility-limitation banner and incomplete parent context.
It is not used as proof of the exact tab-peek pipeline.

### Frame excerpts and attribution

Frame excerpts are from Mitchell Hashimoto's public development videos, retained
with their original content for UI analysis. The complete recordings remain at
the cited source posts.

| Asset | Original post | Playback time |
| --- | --- | --- |
| `assets/rex-tab-peek-00s.png` | August 12 tab peek | 0.0 s |
| `assets/rex-tab-peek-02s.png` | August 12 tab peek | 2.0 s |
| `assets/rex-tab-overview-09-5s.png` | August 12 tab peek | 9.5 s |
| `assets/rex-tab-peek-12s.png` | August 12 tab peek | 12.0 s |
| `assets/rex-split-before-00-5s.png` | June 25 split prototype | 0.5 s |
| `assets/rex-split-entering-01s.png` | June 25 split prototype | 1.0 s |
| `assets/rex-split-settled-02s.png` | June 25 split prototype | 2.0 s |

The inspected recordings were 13.516667 s at 3132 × 2160 / encoded 60 fps, and
40.083333 s at 1862 × 1272 / encoded 120 fps. Those encoding rates do not prove
the application's frame rate, latency or power use. Changing visible terminal
contents can reflect scrolling rather than newly generated process output.

### Static rendering evidence

[The binary note](evidence/rex-binary-inspection.md) retains the build identity
and reproducible address map. The accepted component trace is:

`TerminalPreviewSurface` → native wrapper → `GhosttyRender.PlatformRenderView`
→ `DrawablePresentationLayer : CAMetalLayer`.

SwiftUI conformance records, allocation/field stores, display-link setup,
source/drawable checks and a guarded automatic-size path were independently
counterchecked. Historical tab-peek usage, complete draw admission, Metal
submission/presentation, texture identity and comparative performance were not
established. No app binary is redistributed.

Exact public searches for GhosttyRender under the checked first-party accounts
and for the candidate preview type did not locate matching public source. The
Superlogical organization had no public repositories at the check. Search nulls
do not prove that the implementation does not exist.

[Bonsplit](https://github.com/almonk/bonsplit/tree/77b9ccebf1c6e6533c3df1030b5efa9a3db2f351)
was read as separate public prior art. Its nested NSSplitView/display-link
animation is not substituted for Rex's described flat-layout kits. No library
adoption is proposed by this preservation.

## Agent identity track

The AgentStudio identity/binding foundations were checked at
[`2fa1b73c5b76b3ebfef7655264853141d4b47cdf`](https://github.com/getagentstudio/agentstudio/tree/2fa1b73c5b76b3ebfef7655264853141d4b47cdf).
They establish pane-specific context, independent pane/zmx identities and
existing provider-conversation binding records. They do not establish complete
continuous selection discovery in an arbitrary native client.

Primary references:

- [Rex agent integration](https://www.superlogical.com/rex/docs/automate/agent-skill)
  and [CLI taxonomy/targets](https://www.superlogical.com/rex/docs/automate/cli).
- [OpenCode TUI plugin API](https://opencode.ai/v2/docs/build/plugins/cli).
- [ccmux TUI plugin at the inspected commit](https://github.com/epilande/ccmux/blob/7debfa271194be4bf89499c909fdb5c307c215f8/src/plugins/opencode/tui.js).
- [WezTerm receiving-pane metadata event](https://wezterm.org/config/lua/window-events/user-var-changed.html).
- [Codex app-server identities](https://developers.openai.com/codex/app-server).
- [Claude status-line input](https://code.claude.com/docs/en/statusline).

The checked launcher source snapshot was `1cf0ce5a6fe23bf840452f39ba7e61e2bc2282e8`.
Its Claude launch target adds `--bg`; supplied notes describe a different
foreground/attach path. This discrepancy remains version-specific rather than
being reconciled by assumption. The local Codex 0.165.0 help was inspected
without starting an app server. A transport option does not establish a current
UI-selection contract.

### Executed plugin experiment

Source:
[`epilande/ccmux@7debfa271194be4bf89499c909fdb5c307c215f8`](https://github.com/epilande/ccmux/tree/7debfa271194be4bf89499c909fdb5c307c215f8).
Runtime: Bun 1.4.4. Unchanged upstream command:

```sh
bun test src/plugins/opencode/tui.test.ts
```

Result: **26 passed, 0 failed, 49 assertions, exit 0**. The actual plugin uses
real temporary marker files with a fake OpenCode route/event context and
injected PID liveness. Its test preload isolates application state before
imports. Dependencies were installed from the frozen lock without lifecycle
scripts; tracked source/test files remained unchanged. The task checkout and
cache were removed after preserving the findings.

Observed: selection markers move/clear; a polling path observes route-only
change; child selection reports root; simultaneous viewers retain one marker
owner; cleanup defeats queued/late work. The upstream tests use timer-based
settling, so this is not deterministic scheduling proof, daemon-to-pane matching,
native client integration or a latency benchmark.

Source file SHA-256:

- Plugin: `9be843d9236b0ba487f58494f437c1508daa026b5924427b66da9245b6f8f39b`.
- Test: `2d45af4daa4758b1d467864b17b9d0983692b1e6052d82beb305843dff40bee1`.

### Supplied notes

The complete 1,131-line conversation research was reviewed. The public reports
preserve its technical synthesis: initial versus continuous association;
client versus execution location; exact identity and multiple viewers;
client-side reporting; launcher/protocol limits; child-process, PTY and FD
boundaries; stale/replayed observations; and adversarial validation cases.
Source-dependent assertions were checked selectively and unexecuted native
experiments are labeled. This is a research input, not owner approval of a
schema, protocol, client fork or implementation plan.
