# Drawer browser: implementation plan

## Record

- **Planning result:** ready
- **Originating planner:** plan-implementation
- **Supersedes:** none
- **Governing basis:** reviewed-four-document-design. [Requirements](../requirements.md), [Specification](../specification.md), [Program Design](../program-design.md), [Verification Design](../verification-design.md). Independent `four-document-design` review by the Reviewer Sidekick (codex-local `01a1b1e0-e88a-7d42-a78e-44a55852a08e`): three findings, all corrected and verified, zero open.
- **Applicability:** delivery branch `feat/drawer-browser`, from `origin/main` at `c3a08e10e`.
- **Delivery context:** requested terminal `pr-ready-unmerged`; delivery grouping `single:drawer-browser`; PR topology `one-pr`; repositories: agentstudio.

## Goal

The browser lives in the drawer with browser tabs, a picker and same-link reuse. An agent in a main terminal pane can open websites and HTML files there. In Zoom the drawer defaults to the right side at 95% height.

**Scope:** R1 to R31. **Non-goals:** the Requirements limits.

## Start condition

The owner approves this plan and the Database changes in Program Design.

## Slices

Run in order on a fresh branch off main. Use `DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer` for build and test, the focused lane below, and `mise run lint` before each commit.

### S1: Zoom default

- **Covers:** R23, R24.
- **Reads:** Specification Zoom; Program Design "Zoom default".
- **Writes:** `DrawerPresentationPreference.swift`, `DrawerLayout.swift` and their doc comments; D-DP-1 in `docs/specs/2026-09-13-drawer-presentation/requirements.md`.
- **Wrong behaviour:** a new pane opens on the terminal side, or a saved choice is rewritten.
- **Proof:** `mise run test:swift -- --filter DrawerPresentationGeometryResolverTests`, plus the persistence and cursor suites.
- **Existing tests:** repair expected values in `DrawerPresentationGeometryResolverTests`, `WorkspaceDrawerCursorAtomTests`, `WorkspaceDrawerPresentationPersistenceTests`, `ZoomPresentationContainerGeometryTests`, `DrawerZoomFrameCurrencyIntegrationTests`. Keep the hidden-Bridge tests.

### S2: Tabs in the browser pane

- **Covers:** R5, R8, R10, R12, R20, R30, R31, and the tab rules behind R3.
- **Reads:** Program Design Components, State, "Pages and tabs", Interface.
- **Writes:** new `WebviewTabList`, `WebviewTabPage`, `BrowserPageAddress` in `Features/Webview`; `WebviewPaneController.swift`; `WebviewPaneContentView.swift`.
- **Wrong behaviour:** a same-link open adds a tab; an inactive page keeps interaction enabled; a runtime command hits the wrong tab; a stale address is matched.
- **Proof:** table tests for `WebviewTabList`, including navigate X to Y then open Y and X, and a reused open keeping order; the switch timing event for R29; controller tests for management state and runtime targeting; an allocation test through `WebviewTabPageFactory` for R28.
- **Stop if:** several `WebPage`s can't share the pane host. That needs a Program Design correction.

### S3: Tab picker

- **Covers:** R6, R7, R8, R9.
- **Requires:** S2.
- **Reads:** Specification Browser tabs; the reference picture; Command rules in `AGENTS.md`.
- **Writes:** picker view in `Features/Webview/Views`, `WebviewNavigationBar.swift`, `AppCommand.showBrowserTabs` with its spec, shortcut and IPC classification.
- **Wrong behaviour:** search misses a tab by address; a row can't be reached by keyboard.
- **Proof:** view-model tests; real frames at three widths, shown beside the reference before test hardening.

### S4: One route into the drawer

- **Covers:** R1, R2, R3, R4.
- **Requires:** S2.
- **Reads:** Program Design Current paths, Components, Interface, Cutover.
- **Writes:** the route in `WorkspaceSurfaceCoordinator`; `openWebview`, `openGitHubWebview`, the management layer create paths; `ActionValidator.swift`; `.insertPane(source: .newWebview)` and the new-tab code in `openWebview` deleted; `AgentStudioIPCLayoutAdapter.addDrawerPane`; the snapshot normalizer before workspace composition.
- **Wrong behaviour:** any route reaches the main layout; a second `drawer.addPane` browser call errors; a saved main-layout browser survives launch, or its removal touches other panes.
- **Proof:** route tests per entry point, validator tests, registration test for a second browser call, normalizer tests for a browser-only tab, a mixed tab and a browser owning a drawer.
- **Existing tests:** repair tests that expect a browser in a tab or the main row. Those expectations are retired by U1.

### S5: Saved tabs

- **Covers:** R11.
- **Requires:** S2.
- **Writes:** `WebviewTabSnapshot` and `WebviewState` in `Core/Models`; migration `019_browser_webviews` as written in Program Design "Database changes"; `PaneContentRecord`, the browser codecs in `WorkspaceCoreRepository+PaneGraphCodecs.swift` and `+PaneGraphMutation.swift`, `deletePaneContentRows`, `deleteBrowserContent(paneIds:)` called from `deletePanesNotIn` and `deleteWorkspace`; `snapshot()`.
- **Wrong behaviour:** tabs lost on relaunch; a browser with no rows fails to open.
- **Proof:** legacy migration, then real repository load, two changed saves, and reload; deletion tests for a pane, an owned drawer browser, an empty snapshot and a workspace, with no orphan rows. Re-check the next free migration number at build time.

### S6: Agent command

- **Covers:** R13 to R19, R21, R22.
- **Requires:** S4.
- **Reads:** Specification command table; Program Design Flow, Concurrency, Failure.
- **Writes:** `AppCommand.showDrawerBrowser` with spec and IPC classification; `IPCQueryContracts.swift`, `IPCLayoutMethodDescriptors.swift`, `AppIPCBuiltInLayoutAndTerminalRegistrations.swift`, `AgentStudioAppIPCService.swift`, `AgentStudioIPCLayoutAdapter.swift`; show queue; CLI files in `Sources/AgentStudioIPCClientCore`.
- **Wrong behaviour:** a Markdown file is accepted; no flag falls back to a pane; another pane is accepted; two unread notices after overlap, a closed browser or a failed create.
- **Proof:** admission table tests, CLI line tests, authorization test, adapter tests with held continuations and owner facts. No sleeps or polling.
- **Existing tests:** repair inventories in `IPCBuiltInMethodCatalogTests`, `IPCBuiltInMethodIndexTests`, `IPCAgentHelpEligibilityTests`, `AppIPCPaneAgentAuthorizationTests` and the service fixtures.
- **Stop if:** `goToPane` doesn't reach `focusDrawerPaneAfterAdmission`.

### S7: Real-app proof and docs

- **Covers:** Verification Design journey 1 to 13. Journey 13 is the resource and opening comparison: a baseline build of `origin/main` at the branch point, a loopback quiet-page server that records request times, and a sampling script for the app and WebKit processes, written in this slice. A failed case blocks the PR.
- **Requires:** all above.
- **Writes:** `docs/architecture/commands/ipc.md`, the `agentstudio` skill text.
- **Proof:** the journey on an isolated debug app, PID targeted, under `verify-agentstudio` rules, with frames for the taste check. Then `mise run test` and `mise run lint`, with counts and exit codes.

## Obligation to proof

| R | Slice | Verification Design | When |
|---|---|---|---|
| R1, R2, R3 | S4 | V1 | S4 tests, journey 1, 2 |
| R4 | S4 | V2 | Journey 3 |
| R5 to R10, R30, R31 | S2, S3 | V3 | S2, S3 tests, journey 4, 5, 12 |
| R11 | S5 | V4 | S5 tests, journey 6 |
| R12, R20 | S2 | V5 | S2 tests, journey 7 |
| R13, R14 | S6 | V6 | Journey 8 |
| R15 to R18 | S6 | V7 | S6 tests |
| R19 | S6 | V8 | Journey 9 |
| R21, R22 | S6 | V9 | S6 tests, journey 10 |
| R23, R24 | S1 | V10 | S1 tests, journey 11 |
| R25, R26, R27, R29 | S7 | V11 | Journey 13 |
| R28 | S2 | V12 | S2 tests |
| U12 | All | Review | PR review |

## Gates

- `mise run test` passes on the final head.
- Full IPC inventory review, as the repo requires for IPC changes.
- Independent implementation review before the PR goes to the owner.

## Risks

- Several `WebPage`s in one pane is the least proven part. Stop condition in S2.
- The sunclaw Ghostty and zmx update may touch shared files. Coordinate with that Lead before S4.
