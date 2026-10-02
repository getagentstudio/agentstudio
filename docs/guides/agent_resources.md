# Agent Resources & Research Guide

This guide provides grounded context, setup procedures, and research tools for agents working on the Agent Studio codebase.

## First-Time Setup

A fresh clone or worktree cannot build or test until its vendored inputs are
prepared. A standalone clone is its own primary worktree. The primary hydrates
and builds Ghostty and zmx once; linked worktrees normally reuse those outputs.
`mise run setup` owns both paths.

### Prerequisites

- **macOS 26 + Xcode 26 toolchain** — the package targets `.macOS(.v26)` and uses current Swift concurrency, Observation, WebKit, and AppKit APIs.
- **mise** — build orchestrator: `brew install mise`
- **swift-format** — code formatter: `brew install swift-format`
- **swiftlint** — stock SwiftLint for `.swiftlint.yml` rules: `brew install swiftlint`
- **xcbeautify** — beautifies swift build/test output: `brew install xcbeautify`

`mise run lint` uses stock SwiftLint for `.swiftlint.yml` rules and the
repo-local SwiftPM/SwiftSyntax architecture linter in
`Tools/AgentStudioArchitectureLint`. Homebrew SwiftLint alone is not the full
lint gate for this repo; the local architecture tool must also pass.

### Bootstrap Steps

Run these in order from the project root:

```bash
# 1. Install pinned tool versions (zig 0.16.0)
mise install

# 2. Check local macOS prerequisites and known env hazards
mise run doctor-mac

# 3. Prepare or reuse vendored artifacts/resources
mise run setup

# 4. Build the Swift app
mise run build
```

Do not initialize vendor submodules or run low-level vendor tasks directly.
Agents use plain `mise run setup` by default. Use
`mise run setup --use-local-vendors` only when the user explicitly requests
Ghostty/zmx vendor work or the accepted task requires changing a vendor. That
explicit mode hydrates and builds private vendor inputs in the current linked
worktree; it is not a recovery switch for ordinary setup failures.

### Vendor Inputs (All Gitignored)

| Artifact | Primary or local-vendor worktree | Shared linked worktree | Required for |
|----------|----------------------------------|------------------------|--------------|
| `Frameworks/GhosttyKit.xcframework` | Built locally | Symlink to primary output | `swift build` (SPM binary target) |
| `Sources/AgentStudio/Resources/ghostty/` | Generated locally | Regular local copy from primary | Runtime shell integration |
| `Sources/AgentStudio/Resources/terminfo/67/ghostty` | Generated locally | Regular local copy from primary | Runtime Ghostty terminfo |
| `vendor/zmx/zig-out/bin/zmx` | Built locally | Reached through a symlink to primary `zig-out` | Session multiplexer backend |

If these inputs are missing or incompatible, rerun `mise run setup`. `mise run
build` consumes them; it does not generate them. A linked worktree whose vendor
pins differ from the primary must prepare the matching pins in the primary, or
use the explicitly authorized local-vendor setup for actual vendor work.

### Verifying the Setup

```bash
# Confirm this worktree's vendor role, inputs, and relevant prerequisites
mise run doctor-mac

# Run tests
mise run test
```

### Task catalog

This guide owns bootstrap, the BridgeWeb Vite loop, zig/Xcode, Swift build-slot
recovery, and the rest of the mise task catalog. The everyday daily-command
subset (`setup`, `build`, `test`, `test:swift`, `format`, `lint`) stays in the
root [AGENTS.md](../../AGENTS.md) operating contract. Discover other tasks with
`mise tasks ls`. For one-task details, run `mise tasks info <name>`.

## BridgeWeb Fast UI Loop

This section owns the BridgeWeb Vite command loop. Root [AGENTS.md](../../AGENTS.md)
hops here for the commands; [BridgeWeb/AGENTS.md](../../BridgeWeb/AGENTS.md) owns
React UI rules.

Always use the existing Swift development backend plus Vite as the primary
iteration loop for Bridge development instead of repeatedly rebuilding the full
app. The default command supervises both processes from the repository root:

```bash
bridge_vite_cache_root="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-vite-cache.XXXXXX")"
BRIDGE_WEB_VITE_CACHE_DIR="$bridge_vite_cache_root" pnpm --dir BridgeWeb run dev
```

Give each live Vite server its own cache directory, including parallel agent
sessions on different ports. A port or browser-tab guard does not isolate Vite's
on-disk dependency cache. Shared cache replacement can leave a running server
advertising dependencies that return `504 Outdated Optimize Dep`; lazy Markdown
workers then fail to load even when the Swift backend and content are healthy.
The E2E launcher already uses an owned `vite-cache` under its fixture data root.
The command above applies the same isolation to manual sessions. A fresh cache
requires initial dependency prebundling; it does not change packaged rendering.
Do not clear another running server's cache or compensate with product retries.

Vite reports frontend readiness before the supervised Swift build finishes.
Wait for the distinct `[bridge-backend] Bridge development server is ready.`
line, then open
`http://127.0.0.1:5173/?fixture=worktree&viewer=review&workers=on&scenario=current-worktree`.
Vite provides React HMR while the Swift backend uses the production Core,
Bridge, `agentstudio-git`, and isolated `core.sqlite`/`local.sqlite` owners.
If SwiftPM reports `sandbox_apply: Operation not permitted` from an agent-run
terminal, rerun the unchanged command with host permission; do not disable the
SwiftPM sandbox in repository code.

For manual backend debugging, start the development backend on a chosen
loopback port, then point Vite at that exact origin with
`BRIDGE_WEB_DEV_BACKEND_ORIGIN`. Without that variable, Vite intentionally
starts and proxies to its own supervised backend.

```bash
mise run build-bridge-development-server
bridge_dev_root="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-bridge-dev.XXXXXX")"
.build-bridge-development-server/agentstudio-bridge-dev-server \
  --data-root "$bridge_dev_root" \
  --pane-id 00000000-0000-7000-8000-000000000001 \
  --seed-worktree "$PWD" \
  --seed-target HEAD \
  --port 43871
BRIDGE_WEB_DEV_BACKEND_ORIGIN=http://127.0.0.1:43871 pnpm --dir BridgeWeb run dev
```

Use the actual app for final validation of packaged WKWebView, native chrome,
App lifecycle, and other boundaries the development server cannot prove.

### Xcode And Zig Vendor Builds

Vendored Ghostty and zmx build with the zig version pinned in `.mise.toml` and the
Xcode version the CI workflows select. No Xcode workaround is currently required.

## Running Swift Commands

**Always use `mise run` for build and test.** Mise tasks handle the WebKit serialized test split, benchmark mode, and build path isolation.

Paired SwiftPM test targets own their module tests.
`AgentStudioTestSupport` depends only on Core; Infrastructure and
SharedComponents tests do not consume it. The executable `AgentStudioTests`
target owns App, cross-Feature, resource, WebKit, zmx, and packaged integration.
Keep the existing fast/large/WebKit/E2E/zmx lane selectors intact:
`swift test --filter` selects execution after the package test products are
built; it does not change target ownership or imply isolated compilation.

**For filtered test runs:** prefer mise (it allocates a slot for you):

```bash
mise run test:swift -- --filter "CommandBarState"
```

If you must invoke `swift test` directly, acquire the test slot and release it from your caller-owned EXIT trap:

```bash
source scripts/swift-build-slot.sh
swift_build_slot_acquire test "manual swift test"
trap swift_build_slot_release EXIT
swift test --build-path "$SWIFT_BUILD_DIR" --filter "CommandBarState"
```

| Env Var | Default | Purpose |
|---------|---------|---------|
| `SWIFT_BUILD_DIR` | `.build-agent-1` for both `build` and `test`; `.build-ci` on CI | The caller acquires the worktree's one slot with `swift_build_slot_acquire build|test "task label"`. Local overrides are not supported. |
| `SWIFT_TEST_PARALLEL` | `1` (enabled) | Set to `0` to disable parallel workers |

### Swift Build-Slot Recovery

**One slot per worktree.** Every Swift build and test task in a worktree uses `.build-agent-1`: debug and release builds, Swift lint and format, the Bridge development-server build, architecture-lint compilation, and test tasks from prebuild through the last test process. A second per-worktree build directory cost several GB of disk, so the owner removed it on 2026-10-01. The `build` or `test` argument only labels the claimant in logs and holder notes; both take the same lock, so a test run in a worktree waits for a build in that worktree, and the reverse.

**Acquisition and release.** The caller runs `swift_build_slot_acquire build|test "task label"`, then installs its own EXIT handler to call `swift_build_slot_release`. The slot is a kernel `flock` on `.build-agent-1/.slot.lock`, held by a small holder process; the kernel drops it whenever that holder exits (release, error, Ctrl-C, `kill -9`, crash), so there are no stale claims to reap and no process inspection, which keeps it working inside agent sandboxes. A waiting caller prints the holder's task, PID and start time once, then waits in the kernel; nothing times out on contention.

**Leftovers.** `mise run clean-agent-builds` removes a stale holder note and any `.slot-claim` directory left by the old ps-based script, only while the slot is free. It never deletes `.slot.lock`. An old `.build-agent-2` directory is no longer used by anything and can be deleted.

**CI path.** CI uses `.build-ci` when `CI=true` or `GITHUB_ACTIONS=true`; the local slot allocator is bypassed. Other caller-provided `SWIFT_BUILD_DIR` values are rejected.

**Contention and lock recovery.** If `mise run build` or a `mise run test:*` task waits, read its one-time holder line. The lanes keep their own hang bounds — `SWIFT_TEST_TIMEOUT_SECONDS` defaults to 600 and `SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS` to 1200 in [`scripts/run-swift-test-task.sh`](../../scripts/run-swift-test-task.sh), matching CI. Do not impose a shorter timeout to detect contention. Run `mise run clean-agent-builds` to remove leftover holder notes. Do not blanket-kill SwiftPM or `swift-build`; inspect the specific owner and wait for it or terminate only a confirmed stale process.

### Peekaboo PID Targeting

When visual/native interaction proof is required, launch the debug binary from
the claimed slot, then target Peekaboo by PID. Never target debug builds by
name. Never `pkill AgentStudio` — it kills the user's running app.

```bash
mise run build # uses build slot .build-agent-1
BUILD_PATH=.build-agent-1
"$BUILD_PATH/debug/AgentStudio" &
PID=$!
peekaboo see --app "PID:$PID" --json
```

Test builds share `.build-agent-1`; for example, `mise run test:swift` acquires
the slot before its prebuild and holds it through the final test process, so a
build in the same worktree waits for it.

Treat Peekaboo output as visual/render/interaction proof, not a replacement for
unit, integration, or marker-scoped observability proof.

## DeepWiki Knowledge Base
Use DeepWiki to gather grounded context on core dependencies and libraries.

- **Ghostty (Core Terminal)**: `ghostty-org/ghostty`
  - *Usage*: `wiki_question(repo: "ghostty-org/ghostty", question: "...")`
  - *Focus*: C API, terminal emulation logic, Zig build system.
- **Swift (Language)**: `swiftlang/swift`
  - *Usage*: `wiki_question(repo: "swiftlang/swift", question: "...")`
  - *Focus*: Language features, standard library, runtime behavior.

## Documentation Links

### Current Swift and Apple Platform References

Use these primary docs when updating architecture docs or implementation details. Do not infer platform behavior from memory when the API has likely moved.

- **Swift docs index**: [https://www.swift.org/documentation/](https://www.swift.org/documentation/)
- **Swift language guide — concurrency**: [https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- **Swift Package Manager**: [https://docs.swift.org/package-manager/](https://docs.swift.org/package-manager/)
- **Swift Testing**: [https://developer.apple.com/documentation/testing](https://developer.apple.com/documentation/testing)
- **AppKit**: [https://developer.apple.com/documentation/appkit](https://developer.apple.com/documentation/appkit)
- **SwiftUI**: [https://developer.apple.com/documentation/swiftui](https://developer.apple.com/documentation/swiftui)
- **SwiftUI/AppKit integration**: [https://developer.apple.com/documentation/swiftui/appkit-integration](https://developer.apple.com/documentation/swiftui/appkit-integration)
- **Observation**: [https://developer.apple.com/documentation/observation](https://developer.apple.com/documentation/observation)
- **WebKit**: [https://developer.apple.com/documentation/webkit](https://developer.apple.com/documentation/webkit)
- **Designing for macOS**: [https://developer.apple.com/design/human-interface-guidelines/designing-for-macos](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)

Project target note: Swift.org may show a newer downloadable Swift toolchain than this repo targets. Follow `Package.swift`, `.mise.toml`, and the Xcode toolchain selected by `doctor-mac` for builds; use the docs links above for current API semantics.

### Dependency and Vendor References

- **Ghostty Docs**: [https://ghostty.org/docs](https://ghostty.org/docs)
- **Pierre Diffs / CodeView Docs**: [https://diffs.com/docs](https://diffs.com/docs)
- **Trees Docs**: [https://trees.software/docs](https://trees.software/docs)
- **Shiki Docs**: [https://shiki.style/](https://shiki.style/)
- **Hunk inspiration**: [https://github.com/modem-dev/hunk](https://github.com/modem-dev/hunk) and [https://deepwiki.com/modem-dev/hunk](https://deepwiki.com/modem-dev/hunk). Use for annotation/review workflow research only; do not copy its terminal UI architecture into the React CodeView pane.
- **swift-async-algorithms**: [https://github.com/apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
- **JSON-RPC 2.0**: [https://www.jsonrpc.org/specification](https://www.jsonrpc.org/specification)
- **Foundation**: [https://developer.apple.com/documentation/foundation](https://developer.apple.com/documentation/foundation)
- **Metal**: [https://developer.apple.com/documentation/metal](https://developer.apple.com/documentation/metal)

## Research Guidance

### C API / Interop
When working on `Ghostty.swift` or `GhosttySurfaceView.swift`, verify C function signatures and memory management patterns in the Ghostty repo. Pay close attention to pointer ownership and lifetime.

### AppKit Patterns
For UI changes in `Sources/AgentStudio/App/`, refer to Apple's AppKit documentation for native macOS behaviors. This includes the responder chain, window delegation, and menu management.

### App Organization
The current app layout is hybrid:

- `App/` owns composition, boot, lifecycle, windows, pane hosting, and cross-feature coordination.
- `Core/` owns shared models, actions, runtime contracts, main-actor atoms, persistence wrappers, and feature-agnostic pane UI.
- `Features/` owns vertical capability slices such as `Terminal`, `Bridge`, `Webview`, `CodeViewer`, `CommandBar`, `RepoExplorer`, and `InboxNotification`.
- `SharedComponents/` owns reusable UI primitives. It imports only `Infrastructure`
  and receives state through explicit values, bindings, callbacks, or shared/infrastructure
  observable view models, not atoms or global stores.
- `Infrastructure/` owns domain-agnostic utilities and external integrations.

Use [Directory Structure — Decision Process](../architecture/structure/directory_structure.md#decision-process-where-does-this-file-go) as the placement source of truth. Organization trees and the compiled DAG: [Source And Target Structure](../architecture/structure/directory_structure.md#source-and-target-structure).

### Zig Build System
Ghostty and zmx are built by `mise run setup` in the primary worktree or an
explicitly authorized local-vendor worktree. Shared linked worktrees reuse those
prepared inputs and may not contain hydrated vendor source. If investigating
build options or optimization flags, inspect the pinned vendor sources in the
primary, or use `mise run setup --use-local-vendors` when the accepted task
requires changing Ghostty or zmx.

### Swift Concurrency
The project targets **macOS 26 only** (`.macOS(.v26)` in `Package.swift`). Use Swift 6.2 concurrency features deliberately: `@MainActor` for UI/state mutation, actors for boundary work, `AsyncStream`/`AsyncThrowingStream` for event streams, and `@concurrent nonisolated` for blocking work that must escape an actor executor. Refer to the [Swift Language Guide](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) and [Pane Runtime EventBus Design](../architecture/runtime/pane_runtime_eventbus_design.md) before changing concurrency boundaries.
