# Session, context and native client read needs

**The client needs status, context and native facts through different read/publication boundaries.** A backend copy can supply selected workflow observations; it cannot observe the current native window, keyboard owner, renderer or viewport by itself.

This bounded source catalog covers 14 current families and 36 existing type/field groups at AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. Counts overlap and do not define a complete UI census or target API. [Structured evidence](../../research/evidence/2026-10-17-daemon-capability-placement/session-native-read-needs.json) and [source walk](../../research/evidence/2026-10-17-daemon-capability-placement/session-native-read-needs.md) retain production composition, decisive pointers, explicit same-HEAD reuse and unexpanded branches. This is current read-model evidence, not a selected target schema, sharing policy or accepted Program Design. No product/runtime/socket/render/performance proof is claimed.

Field names follow current Swift declarations and projections. They are not complete replacement wire schemas. In particular a provider conversation, binding generation, execution session, pane and connection retain different identity meanings. A current DTO named SessionSummary does not merge those resources.

## Reads can cross a write boundary

Compact `PaneContextService.computeDisplay` calls a SQL write. Its capture expires agent lines, marks retention-selected settled messages hidden and bumps revisions before folding counts. Detail hydration/startup settlement, answer-receipt confirmation and explicit person mark-read are different operations. A Gateway cache/projection read must not replay those authoritative effects from copied rows. [Display call](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Presentation.swift:106), [capture](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextStorage+MessageProjection.swift:17), [line expiry](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Lifecycle.swift:256), [visibility maintenance](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Lifecycle.swift:312).

The existing status publication, compact display and full paged detail also have separate currentness and removal rules. A failed read can preserve a prior desired publication; rendering detail does not acknowledge an answer or mark a notice read.

## Current consumer families

### S01-session-summary-and-query

- `SessionSummary`: id (binding conversation UUID); provider; sessionRef (provider conversation reference); bindingGeneration; status; providerPrompts[reason,observedAt,summary?]; omittedPromptCount.
- `AgentSessionStatus`: needsYou(approval|question|blocked); failed(category); working(active|monitoring); idle(done|ready|interrupted|ended); unknown.
- `SessionsStatusReadResult / IPCSessionQueryResult`: unbound | live(summary) | ended(summary); wire: paneId, sourceHealth, session?, lastRefusal?.

**Source owner.** SessionsIngestion owns mutable SessionsStatusRuntime; SessionsRepository.statusContext supplies binding/evidence rows for lazy restore. Current binding generation selects one binding/state; summary is not the provider process itself.

**Reduction/join.** Runtime replays only applied status evidence in admission order per binding, overlays independent ask/line/viewed inputs, and derives status. Approval/question/blocked takes precedence, then ended binding, then turn status. Only monitoring line work refines an already-working turn.

**Projection/contraction.** SessionSummaryProjection sorts prompts newest first, caps listed prompts and summary/failure text; omittedPromptCount preserves omitted count. Reduction uses full state rather than truncated prompt list.

**Read-side effect.** readSessionStatus may restore runtime state, load open asks, consume viewed/retired mailbox inputs and publish status. lastRefusal read also consumes viewed inputs. Open-ask hydration can reach PaneContextService.ensureOpen through actual bridge.

**Native boundary.** No direct NSWindow/NSView read in summary owner. Person-viewed is an input supplied by native interaction; current summary is not a substitute for actual renderer/process observation.

**Meaning still unselected.** Current source does not decide cross-client audience, retention/replay or whether one client's viewed input changes another client's displayed done/ready state.

**Currentness.** bindingGeneration selects current pane binding; admission sequence/turn IDs guard evidence and closed turns; restored bindings lack live process-local bound instant/confirmation; sourceHealth is same actor current-generation read, not native runtime lifecycle.

**Consumers.** AgentStudioIPCSessionsAdapter.readSessionState → session.query; PaneContextService sessionSummary bridge → PaneContextDetail and display revision inputs.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/SessionSummary.swift:3), [source](../../../../../Sources/AgentStudio/Features/Sessions/Models/SessionsStatusRuntime.swift:16), [source](../../../../../Sources/AgentStudio/Features/Sessions/Models/SessionsStatusRuntime.swift:74), [source](../../../../../Sources/AgentStudio/Features/Sessions/Models/SessionStatusState.swift:211).

### S02-session-status-publication-and-ui

- `SessionStatusPublication`: set(AgentSessionStatus); remove; batch key: PaneId.
- `SessionStatusAtom`: keyed optional AgentSessionStatus; AtomFamily revision/equality suppression.

**Source owner.** SessionsIngestion.publishStatus reads current generation's runtime state and offers status to its mailbox. Production AppDelegate creates composition and supplies a sink applying batches to atomStore.sessionStatus.

**Reduction/join.** Publication omits full SessionSummary, provider identity/prompts and binding generation from payload. App composes keyed status and pane-context readers; RepoExplorer captures them independently.

**Projection/contraction.** Mailbox compares last desired status including in-flight values, coalesces latest keyed values, preserves remove, and rejects retired panes. One lane drains through awaited MainActor sink; atom equal-suppresses again.

**Read-side effect.** Atom keyed read is observation; publication is fed by reducer/lifecycle work. Querying Sessions can independently cause hydration/publication (S01).

**Native boundary.** MainActor atom is app UI publication, not authoritative SQL/runtime state. Consumer has local selected/compact row presentation and observation state.

**Meaning still unselected.** A current per-pane latest-value publication does not select future distributed ordering, subscriber cut, reconnect incarnation or shared versus per-client presentation.

**Currentness.** runtime binding generation guarded before offer; publication payload has PaneId/status only, no explicit binding/revision/incarnation; retired set prevents later offer; keyed remove crosses sink; mutable state stays in ingestion rather than publication atom.

**Consumers.** PaneContextUIReaders.sessionStatusForPane; SidebarSurfaceHost injected reader → RepoExplorerProjectionInputCapture; RepoExplorerPaneRowVariants renders status line when present.

Sources: [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift:299), [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift:325), [source](../../../../../Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion+Status.swift:219), [source](../../../../../Sources/AgentStudio/Features/Sessions/Runtime/SessionStatusPublicationMailbox.swift:5).

### S03-committed-open-ask-input-to-session-status

- `PaneContextOpenAskUpdate`: bindingGenerationId; sequence:Int64; approval:Int; question:Int; blocked:Int.
- `SessionsOpenAskUpdate / OpenAskSummary`: bindingGenerationId; summary(sequence,approval,question,blocked).

**Source owner.** PaneContextService/SQLite counts open pane_request rows by sender binding generation and reason. When advancing, ask_sequence increments in pane_answer_position; hydration reads existing sequence without advancing.

**Reduction/join.** App's PaneContextSessionsBridge translates Core summary into Sessions-owned port. Sessions retains latest independent ask summary per binding generation; drops non-increasing sequence; status reducer combines counts with provider prompt reasons.

**Projection/contraction.** Counts are independently sequenced facts, not copies of provider prompts or UI message-chip counts. Payload has no bodies, forms, answers or receipt detail.

**Read-side effect.** openAskSummaries invokes ensureOpen, which can settle startup asks/drain retirements; read of existing summary itself uses advancing:false. Ask mutation/settlement produces advancing summary separately.

**Native boundary.** No view required to compute committed counts; user answer is separate person action and not implied by count read.

**Meaning still unselected.** Current source does not select distributed ask ownership, client-specific acknowledgement, shared audience or cross-service replay semantics.

**Currentness.** binding generation qualifies session sender; strictly increasing ask summary sequence; pending summary can precede restored runtime state; Core and Sessions types are distinct mapped ports.

**Consumers.** SessionsIngestion.receiveOpenAskSummary → SessionStatusReducer; SessionSummary/status publication derived needsYou priority.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/PaneContextOpenAskUpdate.swift:4), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextStorage+OpenAsks.swift:5), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextStorage+OpenAsks.swift:47), [source](../../../../../Sources/AgentStudio/App/PaneContext/PaneContextSessionsBridge.swift:24).

### S04-agent-title-and-agent-line

- `AgentLineDetail`: summary; work:working(indeterminate|step(current,total)) | monitoring(text) | blockedOnYou(action) | done | failed(summary); detail?; refs:[MessageAction]; writer:AgentMessageSender; updatedAt; lifetime:untilReplaced|expires(at); stale.
- `agentTitle`: optional current title string.

**Source owner.** PaneContextService ordered write owner writes pane_state under current pane/binding and writer-stream epoch/counter admission. Title/line details are decoded from SQL; line expiry/staleness is time-dependent.

**Reduction/join.** Line write for session sender forwards work+binding generation to App bridge; only Core monitoring maps to Sessions monitoring. Working/done/blocked/failed line states do not override Sessions turn outcome. Display title reader chooses agentTitle before fallback pane.title.

**Projection/contraction.** Compact PaneContextDisplay carries full current AgentLineDetail but no line history. Ordered current-value writes differ from publication equality/coalescing.

**Read-side effect.** Compact display capture can expire line in SQL and bump revision. Detail read computes staleness/read-time version and calls ensureOpen; receipt acknowledgement is separate.

**Native boundary.** Fallback pane title/CWD may be current native terminal metadata; line's semantic work is not renderer state. OS file/pane/PR actions in refs have separate native/effect owners.

**Meaning still unselected.** Source does not select cross-client title/line audience or where expiry time is evaluated in distributed execution.

**Currentness.** writer includes pane or session(provider,sessionRef,bindingGeneration); write stream epoch and increasing counter; binding generation checked inside transaction; expiry Date and stale bit/read-time version can change display/detail revision.

**Consumers.** PaneContextDisplay → RepoExplorer agent-line row and context popover; PaneDisplayTitleDerived.title override → PaneContextUIReaders.titleForPane; SessionStatusReducer monitoring refinement through bridge.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/AgentLineDetail.swift:3), [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/AgentMessageDetail.swift:53), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+OrderedWrites.swift:24), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+OrderedWrites.swift:54).

### P01-pane-context-compact-display-and-counts

- `PaneContextDisplay`: revision:PaneContextRevision; agentTitle?; agentLine?; own:PaneMessageCounts; includingDrawers:PaneMessageCounts; pullRequests:PullRequestSummaryDetail.
- `PaneMessageCounts`: needsApprovalCount; needsReplyCount; attentionCount; informationalCount; newestOpenBlockingAskId?.
- `PaneContextPublication`: set(display)|remove; batch key:PaneId.

**Source owner.** PaneContextService joins canonical membership sources, Sessions summary and SQL current title/line/message projections. Actual production composition publishes through PaneContextPublicationLane to PaneContextPresentationAtom.

**Reduction/join.** Own fold uses first source; includingDrawers folds owner+validated owned drawer children. Classification includes only open asks/unread notices that are not hidden. Newest approval uses sentAt then source order then position. Current producer sets pullRequests:notApplicable.

**Projection/contraction.** Mailbox compares desired display even in-flight, coalesces keyed pending state, suppresses equality, preserves remove and filters absent/retired panes; MainActor atom suppresses equal values again.

**Read-side effect.** computeDisplay uses sqliteAccess.write. capturePaneContextDisplay expires agent lines, marks retention-selected settled rows display_hidden and bumps revisions before count fold. Failed read preserves desired publication rather than deciding removal.

**Native boundary.** Consumer location/drawer visibility/selected row and visible popover are app presentation state; counts themselves are SQL/domain folds.

**Meaning still unselected.** Current own-versus-owned-drawers aggregation is not selection of cross-client pane membership, retention, publication scope or history.

**Currentness.** membership view sources+per-owner revision rechecked after SQL await; source SQL revisions, session summary and read-time versions produce in-memory detailRevision; stale older source revision completion can reuse newer desired display; publication set contains revision but no separately typed service incarnation.

**Consumers.** PaneContextUIReaders.contextDisplayForPane; PaneContextToolbarControls keyed task shapes count chip; drawer uses own counts, parent can include drawers; RepoExplorer captures contextDisplay and constructs row/count chip; PopoverHost observes display revision to refresh detail.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextDisplay.swift:1), [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/PaneMessageCounts.swift:1), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Presentation.swift:106), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextStorage+MessageProjection.swift:17).

### P02-pane-membership-view-source-boundary

- `PaneContextMembershipEntry`: paneId; placement; ownedDrawerChildIds.
- `PaneContextMembershipInstallation`: workspaceId; membershipRevision; entries.
- `PaneContextMembershipView`: workspaceId; membershipRevision; sources:[PaneId].

**Source owner.** Workspace canonical graph supplies compact presence/placement/owned child IDs. Prepared composition installs the directory; graph commits changed/removed entries into it.

**Reduction/join.** Layout owner sources are owner first plus children whose parent/owned-child relationship agrees. Non-layout entry sources are self only. Affected owner set includes previous/new parent/children so display reconciliation sees relationship changes.

**Projection/contraction.** Mutex-backed directory carries keyed entries/versions and coalesced affected owners; wakes are bufferingNewest(1), backed by retained pending invalidation state.

**Read-side effect.** Taking affected owners consumes pending invalidations; view lookup itself is read. Reconciliation drives display reads and their maintenance (P01).

**Native boundary.** Presence/placement is graph truth, not proof a native host/window/surface exists.

**Meaning still unselected.** Whether layout/drawer membership is shared, per client or per attachment is not selected by this source map.

**Currentness.** workspace ID qualifies installation; global revision advances on semantic commit; per-owner version stamped for affected entries; display reconciliation compares current captured owner revisions before full reconcile.

**Consumers.** PaneContextService.captureMembershipView/readDetail/computeDisplay; publication mailbox presence check; App own-pane/service source joins through same directory.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextMembershipDirectory.swift:4), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextMembershipDirectory.swift:52), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextMembershipDirectory.swift:85), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextMembershipDirectory.swift:96).

### P03-pane-context-detail-and-paged-content

- `PaneContextDetail`: paneId; revision; agentTitle?; agentLine?; session?; messages:[AgentMessageDetail]; drawerMessages[sourcePaneId,messages]; links; pullRequests; truncation?.
- `AgentMessageDetail`: id; sourcePaneId; sender(pane|session with binding generation); sentAt; sourceOccurredAt?; importance(info|attention|done|failure); body; why?; actions(openFile|openPullRequest|goToPane); shape:notice(state)|ask(reason,form,waiting,state).
- `AskState / AnswerReceipt`: open|answered(by,value,receipt)|handedBack|dismissed|expired|withdrawn|stale; receipt:notYetConfirmed|confirmed(at)|unconfirmed.
- `PaneContextReadPage / LiveMessageCursor / DetailTruncation`: first|more(source,after(rank,position))|moreSources(after source); omitted[source,openAsks,unreadNotices,next cursor]; remainingLiveSources; nextSourcesAfter.

**Source owner.** PaneContextService reads membership, Sessions summary and SQL snapshot, with retirement/source-page checks. IPC mapping makes equivalent wire fields; UI adapter delegates to same service rather than owning another query.

**Reduction/join.** Page assembly ranks live open asks before unread notices, newest position within rank; source-scoped cursors select continuation; metadata/header/message budgets preserve omitted-source continuation. Current assembly emits links:unknown and pullRequests:notApplicable.

**Projection/contraction.** UI read bounded by domain budget; IPC adapter additionally fits encoded reply including envelope by repeat bounded detail reads. Session prompt summary is independently bounded (S01).

**Read-side effect.** ensureOpen can perform startup blocking-ask settlement and drain retirements. Ordinary detail snapshot uses sqliteAccess.read and updates in-memory detail versions; it does not mark notices read. pane.message.changes separately confirms receipts/positions and may prune.

**Native boundary.** Detail contains pane/SQL/domain state, not current NSView/frame/terminal bytes. Message actions require separate actual native/platform effect path.

**Meaning still unselected.** Cross-client page snapshot lifetime, source ordering, retention and receipt ownership are not selected by current local cursor/version fields.

**Currentness.** detailRevision version includes sources, membershipRevision, SQL source revisions, session, line stale and visible-settled identities; detailRevision is maintained in service memory, not a durable global snapshot ID. The service checks page-source membership before awaiting the snapshot and pending retirement afterward; unlike compact `computeDisplay`, `readDetail` does not recheck the directory's source set/revision after that await. Native paging adds its own request-generation and revision checks. Wire safe-integer and reply budget checks do not retain a snapshot. [Service checks](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Detail.swift:27) · [native paging](../../../../../Sources/AgentStudio/App/PaneContext/PaneContextPopoverPaging.swift:9).

**Consumers.** PaneContextPopoverController → PaneContextUIAdapter.readDetail; pane.context.get → AgentStudioIPCPaneContextAdapter/read mapping; popover shaping uses current local source titles.

Sources: [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/PaneContextDetailReading.swift:3), [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/PaneContextDetailReading.swift:64), [source](../../../../../Sources/AgentStudio/Core/PaneContext/Contracts/AgentMessageDetail.swift:3), [source](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Detail.swift:27).

### P04-native-context-popover-consumer-state

- `PaneContextPopoverController`: paneId?; state:PaneContextPopoverShape?; unavailableNote?; actionFeedback?; location; includingDrawers; private request generation; retained detail?.
- `PaneContextPopoverPageUpdate`: restartFirst; detail(PaneContextDetail).

**Source owner.** App UI controller owns open/popover location, request generation and retained paged detail. It reads current service through PaneContextUIReaders.serviceProvider; production boot injects the actual PaneContextService UI adapter.

**Reduction/join.** After each await, controller checks request generation/pane. Paging merges only same pane+revision, replaces messages by ID and drawer groups by source; changed revision restarts first page; sourceNotInView drops source and rereads first. Shaping uses current title reader for owner/drawers.

**Projection/contraction.** Displayed compact counts and full popover shape are distinct consumer projections; .task keyed to display revision refreshes only while presented.

**Read-side effect.** Opening/refresh itself invokes readDetail; person mutations are separate calls followed by refresh. No automatic receipt confirmation inferred from rendering a page.

**Native boundary.** Presented/open state, location, local titles, in-flight generation and selected controls belong to this UI instance; backend summary alone does not observe them.

**Meaning still unselected.** No future remote-client drafts, popover state sharing or command location authority is chosen here.

**Currentness.** refresh/more/close/service loss increment UI generation; stale async result is rejected; revision equality required for multi-page merge; popover close clears retained state.

**Consumers.** PaneContextPopoverHost pane/sidebar locations; answer/dismiss/markRead/runAction/dismissAll via person port; answer and runAction restricted to pane location; markRead explicit then refresh.

Sources: [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+MainWindowCreation.swift:104), [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift:350), [source](../../../../../Sources/AgentStudio/App/PaneContext/PaneContextUIReaders.swift:30), [source](../../../../../Sources/AgentStudio/App/PaneContext/PaneContextPopoverController.swift:37).

### N01-workspace-pane-query-projections

- `ProgrammaticControlWorkspaceSnapshot`: id; name; tabs[id,name,paneIds,activePaneId,isActive]; panes[id,title,contentKind,residency,tabId?,repoId?,worktreeId?,isActive,isDrawerChild]; repositories[id,name,path,worktrees[id,repoId,name,path,isMainWorktree]]; activeTabId?.
- `IPCWorkspaceSummary / IPCTabSummary / IPCPaneSummary / IPCPaneSnapshotResult`: workspace:id,ordinal,name,tabCount,paneCount,repositories,isCurrent; tab:id,ordinal,name,paneIds,activePaneId?,isActive; pane:id,ordinal,contentKind,residency,tabId?,repoId?,worktreeId?,isActive,isDrawerChild,activity?; snapshot:pane,tab?,workspace.

**Source owner.** WorkspaceStore.programmaticControlSnapshot captures identity/tab layout/pane graph/repository topology atoms on MainActor. Query adapter adds window currentness and activity. This is a projection of app-composed state, not per-read SQL/Git acquisition.

**Reduction/join.** Pane ordering visits tabs' activePaneIds then remaining panes sorted by UUID. Source URLs become path strings. IPC tabSummary currently writes name:"" despite internal snapshot retaining tab.name; IPCPaneSummary omits internal title.

**Projection/contraction.** pane.list/current/snapshot principal-filter activity; own-pane snapshot rechecks existence/membership in same MainActor read. Current pane is activeTab.activePaneId, not normalized drawer/native first-responder focus.

**Read-side effect.** Snapshot/projection path reads current atoms; no per-request persistence or source refresh. Current state is not an operation receipt.

**Native boundary.** Graph existence/residency does not prove native host/surface; active/main pane differs from normalized focused drawer and actual first responder.

**Meaning still unselected.** Current app graph/projection does not select future shared versus client arrangement, active tab, pane membership or remote path meaning.

**Currentness.** no explicit capture revision/service incarnation in these DTOs; ordinals depend on current presentation order; currentWorkspace/currentPane/snapshotPane require currentWindow; list methods do not add that guard; server composition itself requires accepting main window.

**Consumers.** window/workspace/pane IPC queries; command target resolution/authorization reads same snapshot; typed layout resolves canonical IDs and current tab/pane relations.

Sources: [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore+ProgrammaticControlSnapshot.swift:18), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore+ProgrammaticControlSnapshot.swift:68), [source](../../../../../Sources/AgentStudioProgrammaticControl/IPCQueryContracts.swift:87), [source](../../../../../Sources/AgentStudioProgrammaticControl/IPCQueryContracts.swift:194).

### N02-focused-pane-and-command-context

- `WorkspaceFocusedPane`: owner:mainPane|emptyDrawer|drawerPane; activeMainPaneId; paneId; repoId?; worktreeId?; contentType.
- `CommandContext`: activeTabId?; focusedPaneId?; focusedRepoId?; focusedWorktreeId?; focusedContentType?; satisfiedRequirements.
- `KeyboardOwner`: otherWindow; managementLayer; sidebar(surface); mainWindowChain.

**Source owner.** WorkspaceFocusedPaneResolver combines active tab/arrangement, active residency, requested WorkspaceFocusOwner and drawer cursor/expansion/minimization. CommandContextDerived adds current layout/zoom capability facts. KeyboardOwner derives native window key ownership plus management/sidebar focus state.

**Reduction/join.** Focus owner is normalized against current graph; empty drawer maps focused content to main pane. Requirements include multiple tabs/panes, arrangements, drawer/expanded child focus and terminal zoom.

**Projection/contraction.** Pure current projections, not manually persisted focused-pane DTO; native first-responder application is a separate effect owner.

**Read-side effect.** Projection itself reads; command dispatch/native focus changes are separate.

**Native boundary.** Current key-window/keyboard interpretation, sidebar focus and local management/transient UI attendance cannot be established from backend session/graph bytes alone.

**Meaning still unselected.** This pass does not choose cross-client focus/controller/keyboard ownership or whether any current focus value is shared.

**Currentness.** re-evaluated from current graph/focus/presentation inputs; no distributed observation generation in value; typed explicit command targets are separate from interactive contextual enablement.

**Consumers.** AppDelegate main-menu shouldPresent/canDispatch context; CommandBarDataSource item construction; RepoExplorer focused row uses KeyboardRoutingContext and attendedPane.

Sources: [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceFocusedPane.swift:4), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceFocusedPaneResolver.swift:7), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/CommandContextDerived.swift:7), [source](../../../../../Sources/AgentStudio/Core/Models/KeyboardOwner.swift:19).

### N03-native-window-lifecycle-and-current-window

- `WindowLifecycleAtom / WindowPresentationFacts`: registeredWindowIds; keyWindowId?; focusedWindowId?; presentation per window:isVisible,isMiniaturized,isOccluded; terminalContainerBounds; isLaunchLayoutSettled; didPublishFirstInteractiveFrame; firstInteractiveFrameSource:presented|occludedFallback.
- `WorkspaceWindowLifecycleSnapshot / IPCWindowSummary`: registered/key/focused/preferred window IDs; wire:id,ordinal,isKey,isFocused,isCurrent,workspaceId.

**Source owner.** NSApplication/NSWindow delegate and App-owned ApplicationLifecycleMonitor publish native facts. MainWindowController samples actual window presentation; first-frame proxy uses CATransaction/main-runloop sources, not Ghostty renderer-present.

**Reduction/join.** Preferred window chooses focused then key then sole registered ID; visibility is separate and not used by this selector. Query projects registry into stable IDs and relative ordinals.

**Projection/contraction.** Presentation equality suppression and one-time usable-frame publication; local waiters/observers have teardown. Window RPC omits full visibility/bounds/launch facts used elsewhere.

**Read-side effect.** Native monitor ingresses mutate atoms; query snapshot reads them. First-frame waiting/observer lifecycle is separate from the snapshot read.

**Native boundary.** Actual Mac window key/focus/visibility/occlusion, geometry, runloop/display progress and system clock/timezone ingress require the native client source; copying Host session state cannot observe them.

**Meaning still unselected.** Future per-client window identity, shared layouts and focus audience are not selected by this current single-app policy.

**Currentness.** transient window/launch facts explicitly never persisted; native registration required before presentation write; no durable execution/session incarnation implied; time/timezone notifications are local background invalidations.

**Consumers.** window.list/current; current workspace/pane gate; KeyboardOwner and command-bar parent/scope; WorkspaceSurfaceCoordinator repository-demand presentation (visible/minimized/occluded); launch restore/readiness consumers.

Sources: [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WindowLifecycleAtom.swift:9), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WindowLifecycleAtom.swift:34), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WindowLifecycleAtom.swift:69), [source](../../../../../Sources/AgentStudio/App/Lifecycle/ApplicationLifecycleMonitor.swift:74).

### N04-terminal-runtime-status-snapshot

- `PaneRuntimeSnapshot`: paneId; metadata:PaneMetadata; lifecycle:created|ready|draining|terminated; capabilities:Set<PaneCapability>; lastSeq; timestamp.
- `TerminalRuntimeSnapshotFacts`: rendererHealthy?; readOnly?; secureInput?.
- `IPCTerminalStatusResult / IPCTerminalSnapshotResult`: status:paneId,lifecycle,isReady,backend,capabilities; snapshot:paneId,lifecycle,backend,capabilities,lastSequence,timestamp,rendererHealthy?,readOnly?,secureInput?.

**Source owner.** RuntimeRegistry selects current app terminal runtime; TerminalRuntime snapshots event channel state and its native-fact properties. Ghostty translation produces renderer-health/secure-input events handled by runtime. timestamp is Date() at capture.

**Reduction/join.** Runtime adapter resolves current terminal pane/type and own-pane scope, maps metadata backend/capability names and optional native fact provider. Snapshot contains no terminal output bytes, grid or screen.

**Projection/contraction.** Native read-only/renderer changes equal-suppress before replayable event emission; runtime-local sequence/replay/subscription are separate from product/socket event catalog.

**Read-side effect.** Snapshot reads current runtime properties/Date; wait allocates temporary subscription/wait lifecycle. No read result is a PTY consumption/process-completion receipt.

**Native boundary.** Mac Ghostty renderer health, local read-only/secure-input and actual surface/first-responder state are native-client observations; process persistence/backend facts do not prove these.

**Meaning still unselected.** No future terminal controller, process incarnation, restore/live ordering, remote renderer fact policy or retained screen/history is selected.

**Currentness.** lastSeq is current runtime event-channel sequence, not durable execution incarnation; timestamp is snapshot capture time, not last event time; lifecycle ready differs from actual backend/process independent health; optional native provider means fact fields can be absent.

**Consumers.** terminal.status/snapshot IPC; terminal.wait uses runtime subscription/replay and condition matcher; runtime commands use current registered owner separately from read DTO.

Sources: [source](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Contracts/PaneRuntimeTypes.swift:52), [source](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/PaneRuntimeEventChannel.swift:93), [source](../../../../../Sources/AgentStudio/Features/Terminal/Runtime/TerminalRuntime.swift:129), [source](../../../../../Sources/AgentStudio/Features/Terminal/Runtime/TerminalRuntime.swift:312).

### N05-pane-activity-time-and-recency

- `PaneActivityOccurrence / PaneActivityTime`: paneId on occurrence; source:hook|terminal; orderingInstant:ContinuousClock.Instant; wallTime:Date.
- `PaneActivityRecord`: paneId; wallTime; source (durable; orderingInstant never stored).
- `IPCPaneActivity`: at (wall time); source.
- `RepoExplorerPaneActivityProjection`: age?; activityDate?; clockText; recencyTier; isActive; unpinned/pinned bucket; nextPresentationChangeDate?.

**Source owner.** PaneActivityClock admits/coalesces occurrences from hook adapter and native TerminalActivityRouter. App sink applies keyed time mutations then attempts datastore commit; restore reconstructs representable monotonic age from stored wall time.

**Reduction/join.** Mailbox retains newest occurrence per pane by monotonic ordering. RepoExplorer derives age from local referenceInstant and wallNow/calendar; IPC exposes only wall time/source and principal filters visibility.

**Projection/contraction.** Runtime atom comparator suppresses equal activity values. Clock cadence, pending/deadline/retirement state contracts input before MainActor publication. Recency text/buckets have local future change dates.

**Read-side effect.** Reads themselves are projections; sink separately applies atom then attempts persistence (failure logged).

**Native boundary.** Terminal-source activity/viewport observation and client calendar/reference clock are native/local inputs; copied wall-time data does not preserve process-local instants or current local recency rendering.

**Meaning still unselected.** Cross-client attendance/time policy, no-client activity, shared recency and retention are not selected by current local projection.

**Currentness.** ContinuousClock.Instant is process-local and reconstructed on restore; per-pane ordering/retirement/deadline generation is not wire event ordering; IPC field at is not a mutation receipt or provider liveness; local calendar/timezone affects recency presentation.

**Consumers.** RepoExplorer current pane row facts and recency grouping/text; pane.list/current/snapshot activity field; terminal/hook activity producers feed same clock.

Sources: [source](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/PaneActivity/PaneActivityOccurrence.swift:8), [source](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/PaneActivity/PaneActivityOccurrence.swift:56), [source](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/PaneActivity/PaneActivityClock.swift:81), [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+TerminalActivityBoot.swift:6).

### N06-pane-latest-output-fragment

- `PaneActivityStatusFact`: lastOutputLine:String; observedAt:Date.

**Source owner.** Production TerminalActivityRouter receives surfaceID lookup and SurfaceManager.readViewportTrailingText callback; settled activity callback records PaneActivityStatusAtom. This is current renderer viewport trailing text, not a stored terminal transcript.

**Reduction/join.** Atom ignores nil/empty text, equal-suppresses lastOutputLine independent of observedAt, retains/replaces one pending value per pane within minimum publish interval and publishes at eligibility deadline.

**Projection/contraction.** Runtime-only latest fragment and clear mutation; not arbitrary history/terminal byte plane. Old Inbox-related comments do not establish active Inbox capability.

**Read-side effect.** Atom status read itself is observation. Native trailing-text acquisition is a separate source callback; publication changes runtime state.

**Native boundary.** Actual current native surface viewport text cannot be inferred from a Host process-lifetime/status copy alone.

**Meaning still unselected.** No future transcript/scrollback retention or detached/no-renderer latest-output source is selected.

**Currentness.** surfaceID lookup/read can report surfaceStale; per-pane pending eligibility and scheduledDeadline fence publication; observedAt is recording time and equal lines do not refresh publication.

**Consumers.** SidebarSurfaceHost.latestPaneMessageSnapshot; RepoExplorerProjectionInputCapture.latestMessageText from activityFact.lastOutputLine.

Sources: [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+TerminalActivityBoot.swift:17), [source](../../../../../Sources/AgentStudio/App/Boot/AppDelegate+TerminalActivityBoot.swift:33), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/PaneActivityStatusAtom.swift:10), [source](../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/PaneActivityStatusAtom.swift:76).

## Data and interface consequences

| Distinction | Consequence for the target contract |
| --- | --- |
| Host execution/provider state versus actual user viewing | Host can reduce shared execution evidence without a Mac. The selected client/user viewing scope separately affects prepared display status; process placement cannot choose that policy |
| Compact counts versus message detail versus receipts | Each has its own revision/scope and effect boundary. Reading a copy cannot confirm answer delivery or mutate retained history |
| Drawer/member composition versus execution ownership | Client presentation can combine several source contexts. Membership/read scope needs a declared source set; it cannot terminate or replace the Host resource |
| Native window/keyboard/renderer facts versus Host observations | Native clients supply actual local facts; unavailable or absent data stays distinct from false/healthy and from graph existence |
| Wall time versus process-local monotonic time | Current activity persists wall time while monotonic order belongs to a running process. Serializing an instant does not make times from different Hosts comparable |
| Full current internal model versus app RPC DTO | Existing RPC fields omit some native/internal read needs. The new schema must follow selected consumers, not copy a DTO just because it is Codable |
| Captured output fragment versus rendered Pane row | Sidebar capture retains latest output text, but the bounded sidebar walk found no read into current prepared Pane row variants. This is not authority to delete the field or export raw terminal text by default |

The [sidebar catalog](sidebar-read-needs.md) supplies the row-level joins and native materialization boundary. The [session status walk](../07-agents-context/research/session-status-ownership.md) supplies the detailed reducer/publication flow and the existing viewed-after-completion policy brief. The [Bridge catalog](../08-files-review-output/client-read-needs.md) covers finite content and publication/application separately.

Target authority, audience, retained history, view/preference scope, cross-Host recency, cache bounds, renderer-independent fact sources and lease-expiry behavior remain in their owning specifications. These source catalogs let the Lead design the concrete view interface without assuming that the current Swift atom, runtime object, database row and public wire type are the same object.
