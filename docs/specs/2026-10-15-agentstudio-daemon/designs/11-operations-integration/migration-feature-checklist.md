# Feature-by-feature migration checklist

**These boxes mean integrated and proven, not merely inventoried or documented.** All42 leaves remain unchecked because this design work has delivered no Rust product implementation. A retained-native feature closes only when its real interaction with migrated state still satisfies its selected contract; it need not be rewritten in Rust. A dormant/refused feature needs an explicit disposition, not automatic resurrection.

Each branch inherits its responsibility, command/observation class and prerequisite below. Each leaf links to its existing feature explanation; the [293-declaration crosswalk](migration-operation-crosswalk.md) expands command/RPC/Git/Bridge coverage by layer. The [18-family acquisition map](capability-placement-map.md) covers non-command ingress too. These are overlapping views, not additive feature counts.

Use this tree beside the [migration/dependency map](migration-map.md) and [detailed near-term slice](near-term-migration.md). Within a slice, contract mapped, design ready, implemented, integration observed and old path retired are separate evidence claims. The work trace owns progress records; this tree never treats a review or inventory pass as delivery.

## Repositories, Git and worktrees

**Responsibilities:** Host Git/source owners; Gateway inventory/preparation; UX input/native follow-up. **Contract home:** [DS05/DS06](../05-git-discovery/specification.md).
**Prerequisite / sequence:** Remote read boundaries → complete mutation/platform contracts.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Git administration and actual filesystem effects; discovery/source validity and partial residue.

- [ ] [Discover repositories and watched folders](../../explainer/feature-migration-guide.md#discover-repositories-and-watched-folders) — Replace source acquisition/admission; compare scoped inventory and coverage while keeping folder choice native.
- [ ] [Read status, tracked paths and ignored files](../../explainer/feature-migration-guide.md#read-status-tracked-paths-and-ignored-files) — Replace Git reads behind the consumer seam; preserve status options, path/ignore and unavailable outcomes.
- [ ] [Inspect branches, remotes and pull requests](../../explainer/feature-migration-guide.md#inspect-branches-remotes-and-pull-requests) — Move addressed Git/Forge acquisition; keep source coverage and native browser initiation separate.
- [ ] [Clone, fetch, push and manage branches](../../explainer/feature-migration-guide.md#clone-fetch-push-and-manage-branches) — Move real effects and staged-fetch cleanup; preserve credential, cancellation, partial and uncertain results.
- [ ] [Create or fork a worktree](../../explainer/feature-migration-guide.md#create-or-fork-a-worktree) — Replace mechanics plus app exclusion/publication/reconciliation policy; prove complete selected Linux fork behavior.
- [ ] [Remove, archive, prune and lock worktrees](../../explainer/feature-migration-guide.md#remove-archive-prune-and-lock-worktrees) — Preserve operation-specific administration/files, retention checks and failure residue; do not equate prune with remove.
- [ ] [Pin repositories and open associated worktrees](../../explainer/feature-migration-guide.md#pin-repositories-and-open-associated-worktrees) — Separate pin/association intent from native opening and Host execution; exact sharing scope remains explicit.

## Terminals and continuing sessions

**Responsibilities:** Host execution/attachment; Gateway routing/bytes; native renderer/control. **Contract home:** [DS04](../04-terminal-runtime/specification.md).
**Prerequisite / sequence:** Remote-session spine; fact source and native navigation keep separate contracts.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Detach is not termination; restored/live bytes and real input, not just a surviving shell.

- [ ] [Start and list terminal executions](../../explainer/feature-migration-guide.md#start-and-list-terminal-executions) — Move execution establishment/registry to Host; split backend identity from legacy pane and Undo custody.
- [ ] [Attach, restore and follow terminal output](../../explainer/feature-migration-guide.md#attach-restore-and-follow-terminal-output) — Connect real backend through Gateway to fresh native renderer; prove ordered restore/live cut and bounded viewers.
- [ ] [Type, resize and hand off control](../../explainer/feature-migration-guide.md#type-resize-and-hand-off-control) — Keep native input capture; move actual controller/resize admission to Host with truthful uncertain input.
- [ ] [Detach, reconnect and terminate](../../explainer/feature-migration-guide.md#detach-reconnect-and-terminate) — Replace pane-driven retirement with separate detach/terminate; join old cleanup and preserve continuing execution.
- [ ] [Read terminal facts and navigate rendered history](../../explainer/feature-migration-guide.md#read-terminal-facts-and-navigate-rendered-history) — Move renderer-free facts to Host; keep actual history/scroll/prompt navigation at the native renderer.

## Agents, hooks and context

**Responsibilities:** Host provider/binding/context owner; Gateway preparation; actual person action native. **Contract home:** [DS07](../07-agents-context/specification.md).
**Prerequisite / sequence:** Execution/context identity and real Host-local admission/transaction boundaries.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Session/binding/order/ask settlement, currentness and actual viewing remain distinct.

- [ ] [Receive provider hooks and agent lifecycle input](../../explainer/feature-migration-guide.md#receive-provider-hooks-and-agent-lifecycle-input) — Move source/admission/reduction to Host-local entry; remove Swift/Gateway dependence for authorized in-session input.
- [ ] [Show sessions, status and attention](../../explainer/feature-migration-guide.md#show-sessions-status-and-attention) — Move Host evidence reduction and Gateway preparation; actual viewing updates selected subject-qualified markers.
- [ ] [Read context and update the agent title or line](../../explainer/feature-migration-guide.md#read-context-and-update-the-agent-title-or-line) — Preserve writer/binding/order and effectful-read distinctions; publish compact prepared values.
- [ ] [Send notices, ask questions and settle answers](../../explainer/feature-migration-guide.md#send-notices-ask-questions-and-settle-answers) — Preserve exact intake/duplicate/settlement/receipt predicates and private co-commit checkpoints.
- [ ] [Install and remove provider integration packages](../../explainer/feature-migration-guide.md#install-and-remove-provider-integration-packages) — Separate addressed installation effects from thin CLI and shipped resources; preserve bootstrap/partial-write boundaries.

## Files, comparisons and viewers

**Responsibilities:** Host finite source owner; Gateway descriptor/view preparation; native/BridgeWeb viewer. **Contract home:** [DS08](../08-files-review-output/specification.md).
**Prerequisite / sequence:** Repository/source contracts → selected finite-content/native integration.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Exact source/bytes, comparison revision and actual viewer publication are separate.

- [ ] [Browse the file tree and read exact content](../../explainer/feature-migration-guide.md#browse-the-file-tree-and-read-exact-content) — Move addressed acquisition and descriptor custody; preserve byte/path/bounds and source-currentness refusal.
- [ ] [Display code and Markdown](../../explainer/feature-migration-guide.md#display-code-and-markdown) — Retain actual native/BridgeWeb rendering and controls; replace only backend/preparation inputs.
- [ ] [Choose comparisons and inspect diffs](../../explainer/feature-migration-guide.md#choose-comparisons-and-inspect-diffs) — Move Git source/target capture and finite content; keep comparison generation and native view result distinct.
- [ ] [Publish a review and mark files viewed](../../explainer/feature-migration-guide.md#publish-a-review-and-mark-files-viewed) — Preserve publication admission/application and actual viewing; extra shared-marker scope remains open.
- [ ] [Browse web pages and control local viewers](../../explainer/feature-migration-guide.md#browse-web-pages-and-control-local-viewers) — Retain native website data and actual viewer control; external commands need real native target/result.

## Annotations, drafts and output

**Responsibilities:** Host annotation workflow; Gateway authorized result; actual native/file destination. **Contract home:** [DS08](../08-files-review-output/annotation-output-lifecycle-design.md).
**Prerequisite / sequence:** Qualified source, edit/revision/transaction and destination-effect contracts.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Preparation, effect and finalization; no copied-row output replay or generic retry.

- [ ] [Keep annotations attached to the right source](../../explainer/feature-migration-guide.md#keep-annotations-attached-to-the-right-source) — Move source/fingerprint and continuity owner; preserve refresh writes and later stale/conflict possibilities.
- [ ] [Create, edit, flush, revert and save drafts](../../explainer/feature-migration-guide.md#create-edit-flush-revert-and-save-drafts) — Keep live editor buffers distinct from Host saved draft/edit fences; preserve revision-specific transaction outcomes.
- [ ] [Resolve threads and recover annotation sessions](../../explainer/feature-migration-guide.md#resolve-threads-and-recover-annotation-sessions) — Preserve thread/session lifecycle and actual durable recovery acknowledgement, not a generic projection update.
- [ ] [Prepare, inspect and explicitly repeat output](../../explainer/feature-migration-guide.md#prepare-inspect-and-explicitly-repeat-output) — Keep exact snapshot/bytes/membership and explicit repeat workflow; no copied-row or transport retry effect.
- [ ] [Copy, choose an output folder and reveal output](../../explainer/feature-migration-guide.md#copy-choose-an-output-folder-and-reveal-output) — Keep actual destination native or Host-local; preserve effect-before-finalization partial/unknown outcomes.

## Windows, panes and everyday UX client interaction

**Responsibilities:** Shared logical authority where selected; Gateway preparation; actual UX owner. **Contract home:** [DS02/DS09/DS10](../10-swift-client/specification.md).
**Prerequisite / sequence:** Existing native shell integration starts early; shared field/Undo/navigation cuts remain explicit.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** Logical layout and native focus/residency differ; native code is retained when it still owns the job.

- [ ] [Create windows, tabs and panes](../../explainer/feature-migration-guide.md#create-windows-tabs-and-panes) — Retain native windows; separate shared logical placement from Host execution creation and native mount.
- [ ] [Move, extract, resize and undo closed views](../../explainer/feature-migration-guide.md#move-extract-resize-and-undo-closed-views) — Split logical mutation, native geometry/residency and Undo retention; no implicit execution kill.
- [ ] [Focus panes, navigate tabs and pin views](../../explainer/feature-migration-guide.md#focus-panes-navigate-tabs-and-pin-views) — Keep actual focus local; do not silently settle logical selection/pin sharing from today's local columns.
- [ ] [Open drawers, management mode and zoomed viewers](../../explainer/feature-migration-guide.md#open-drawers-management-mode-and-zoomed-viewers) — Retain native modes/focus; separate any logical-layout or execution operation and prove actual effect.
- [ ] [Search, group and filter sidebars](../../explainer/feature-migration-guide.md#search-group-and-filter-sidebars) — Move portable semantic preparation off MainActor; preserve native intent/metrics, source witnesses and changed publication.
- [ ] [Save and restore arrangements](../../explainer/feature-migration-guide.md#save-and-restore-arrangements) — Use selected shared logical authority with revision checks; exact field/navigation/Undo import cuts stay open.
- [ ] [Use the command bar and shortcuts](../../explainer/feature-migration-guide.md#use-the-command-bar-and-shortcuts) — Retain one identity/display/shortcut catalog; rewire each backend part without granting IPC authority from visibility.
- [ ] [Edit pane notes and open external destinations](../../explainer/feature-migration-guide.md#edit-pane-notes-and-open-external-destinations) — Separate note/pin scope from actual clipboard/editor/Finder initiation and remote path representation.

## Settings, integrations and operation

**Responsibilities:** Actual process/credential/authority owner; thin frontend; native consent. **Contract home:** [DS01/DS03/DS09/DS11](specification.md).
**Prerequisite / sequence:** Minimum admission/package/resource support accompanies each usable slice.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** No raw credential export, Gateway lease issuer, mandatory Fleet or bot-server dependency.

- [ ] [Preferences, sign-in and private credentials](../../explainer/feature-migration-guide.md#preferences-sign-in-and-private-credentials) — Retain actual native consent and private boundary; do not turn placeholders or copied rows into authentication.
- [ ] [CLI, MCP, socket methods and subscriptions](../../explainer/feature-migration-guide.md#cli-mcp-socket-methods-and-subscriptions) — Use thin adapters to shared operations; preserve attached target, Host-local exception, exposure and subscription gaps.
- [ ] [Retained state, read copies and offline views](../../explainer/feature-migration-guide.md#retained-state-read-copies-and-offline-views) — Admit selected schemas/audiences/transactions and copy cuts; no whole-file move, fallback writer or hidden spool.
- [ ] [Diagnostics, telemetry and developer surfaces](../../explainer/feature-migration-guide.md#diagnostics-telemetry-and-developer-surfaces) — Keep scrubbed process diagnostics and native telemetry at real owners; no production role inferred from dev HTTP host.
- [ ] [Install, start, stop and update the system](../../explainer/feature-migration-guide.md#install-start-stop-and-update-the-system) — Wire supported artifacts/backend resources and owned runtime tasks; Mac proof does not qualify Linux or iOS.

## Unavailable, debug and uncertain paths

**Responsibilities:** Retain exact refusal/dormancy until explicit product selection. **Contract home:** [Current source boundary](../10-swift-client/command-execution-map.md).
**Prerequisite / sequence:** Explicit disposition before any activation or removal.
**Commands and data:** [named operation group](migration-operation-crosswalk.md); [incoming family paths](migration-map.md#observations-are-not-commands).
**Preserve at cutover:** A method name/log/queued result is not a working effect; dormant paths stay visible.

- [ ] [Keep dormant and refused commands visible](../../explainer/feature-migration-guide.md#keep-dormant-and-refused-commands-visible) — Preserve an explicit unavailable/retired/debug disposition until authorized otherwise; interactive siblings remain independent.
- [ ] [Preserve honest effect and completion boundaries](../../explainer/feature-migration-guide.md#preserve-honest-effect-and-completion-boundaries) — Replace misleading generic success only through the selected operation contract; retain queued/applied/committed/observed distinctions.

## Storage and non-SQL source closure

- [ ] For each included state-bearing feature, bind its exact rows/fields, source validity, private checkpoints, audience and lifetime; use the [86-table/597-column map](../02-data-ownership-replication/storage-placement-matrix.md), not a blanket whole-file move.
  - [ ] Preserve real session/binding/context and private notice-cursor transaction predicates.
  - [ ] Preserve annotation preparation/finalization and separate external destination effects.
  - [ ] Split logical workspace, backend identity/custody and native state; keep Undo retention and R5/R6 execution survival distinct.
  - [ ] Preserve filesystem/Git coverage and source cursor semantics; a copied cursor cannot create a live source.
  - [ ] Cover non-SQL owners too: actual Git files/admin/index/refs, ZMX process/terminal state, native website data, preferences/resources and diagnostic state. SQL replication cannot replace them.

## No silent exclusions

This tree accounts for all42currently recorded feature leaves, not every possible repository behavior. Finite catalogs do not prove there are no unknown features. A newly discovered branch, unsupported platform case, parameter variant, native control or private producer path is added under its real feature before that feature is accepted. No future release ordering, new endpoint or feature activation follows merely from a checkbox.
