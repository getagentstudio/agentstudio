# Bridge Navigation and Drawer Presentation — Requirements

The job is to reach the files an agent is working on, then read, review, and
annotate them in Bridge without having to relocate the agent's terminal.
Files may be in another worktree, another Git repository, or an ordinary local
directory outside Git. Git Review remains worktree-scoped. Supporting
drawer content should remain usable without confusing its owning pane, its
visible position, and the worktree being read in Bridge.

The [current system analysis](../../wip/2026-09-13-drawer-bridge-system-analysis.md)
grounds the normal/Zoom drawer and Bridge boundaries. The
[proposal and tradeoffs](./2026-09-12-proposal-and-tradeoffs.md) retain the
navigation alternatives. The [command-first specification](./2026-09-12-bridge-navigation.md)
defines the source/navigation slice and points to the separate drawer contract.
Earlier recommendations do not override the owner decisions recorded here.
The [Program Design](./program-design.md) is the separate structural artifact.

## People and their jobs

- **Human developer/reviewer:** find a file, inspect the right Git comparison,
  annotate it, and use supporting drawer terminals/browser content in normal
  and full-screen presentation without losing orientation.
- **Agent or developer using automation:** name the intended repository/worktree
  and file, open the appropriate Bridge surface, and determine whether navigation
  actually reached that destination.
- The human remains the beneficiary and product decision maker. No separate
  operator, buyer, or remote collaboration service is introduced by this request.
  The same human and agent callers also manage the worktrees available for browsing.

## Source of the needs

The Agent Studio owner supplied the following statements in the 2026-09-12/13
conversation that requested these documents. These excerpts preserve authority
independently of the author's interpretation of the current code.

| Source | Owner statement | Meaning carried forward |
| --- | --- | --- |
| S1 | “having the ability to search files and go to files in just command mode in the bridge, through the command spec or another system, is pretty important” | Keyboard/command-based file navigation matters. |
| S2 | “there's no mechanism to open a file in the bridge directly to that file or review mode” | The desired outcome is direct arrival at a file or its review. The claimed absence of IPC is observational and was corrected by source research. |
| S3 | “in the same CWD the agent's still working, and I make a new work tree. Now all the edits are in a new work tree, and I have no way to read the files easily with full-screen mode” | Reading another worktree while the agent continues is a material journey. S27 clarifies that any reason for working elsewhere qualifies, including a related repository. |
| S4 | “having the Git for the review is very important for how the bridge works” and “without destroying the models that we use to build the bridge” | Preserve trustworthy Git context and the existing Bridge foundation. |
| S5 | “agents can accles accress cwd, or spin up didfrent repos and i cant view them. the bridge view is butiful with annoation, i want ot use it mroe efficiently” | Different repositories and annotation-capable reading belong in scope. |
| S6 | “Git repos/worktrees only for now” | Earlier scope, superseded for Files by S19. Git Review remains limited to Git worktrees. |
| S7 | “make a design proposal and the trade offs” and “requriements first so i can reivew didfent tradeoffs (use diffrent files)” | Author reviewable alternatives in separate documents; do not treat recommendations as selected behavior. |
| S8 | “bridge doestn open in drawers, cant be dragge dinto panes” | Bridge is not drawer content and cannot be dragged into ordinary pane layouts. This is a new placement restriction, not a description of every current model/restore path. |
| S9 | “we gonna fix fulls creen bugs with atha gab” and “the drag is sometimes jittery and changes, so we need to look into that” | Correct full-screen drawer alignment and investigate/fix unstable top-edge resizing. |
| S10 | “we should save it separately for each pane and also for full screen mode” | Normal and full-screen presentation preferences must not overwrite another pane's choices or each other. The later fixed full-screen shape removes the need for a user-resized full-screen height. |
| S11 | “The first version: we don't even allow the resizing on the right and the left” and “in full screen maybe we dont have top edge resizign eitehr just a gap and over lay ... like 15% on the top” | First version keeps top-edge resize only in normal mode; full-screen uses a fixed overlay with exposed context above it. Approximately 15% is the visual target to check. |
| S12 | “in full screen we just have two more commands to move from one side to another side. It's either on top of the terminal or on top of the bridge view” and “we can just move the anchor” | Full-screen side selection moves the overlay and its visual connection, not its owned child panes. The right-hand content-switcher proposal is superseded. |
| S13 | “yes follow bridge widge” in response to a 70/30-divider example | Fit the actual selected region. The earlier 50% minimum is superseded. |
| S14 | “the drawer widge shoudl be a 2-5% less to allwo teh shadown to work ... whatever side its on in fulls creen mdoe” | Full-screen width has a 2–5% reduction relative to that region so it visibly reads as an overlay. Total-width reduction and centering are the current concrete interpretation. |
| S15 | “drawer in a bridge tab is fine it seems very useful” | A Bridge tab may own its own drawer in normal mode. This corrects the earlier blanket interpretation that no normal drawer could overlay Bridge. Bridge-as-drawer-content remains excluded. |
| S16 | “lets do a full analysis on the sysetm then spedc” after invoking orchestrator-design | Ground the affected system before Specification; remain in design, with Requirements first. |
| S17 | “lets talk about how this will work without track 3 we can do that later as a separate PR” (transcription normalized) | File navigation may consume Bridge source switching; multi-worktree/repository working-context membership is deferred to a later separate PR. |
| S18 | “the associated bridge has a stable destination ... how it is seeded, what it's associated with ... that's settled” | A terminal has one current CWD-derived repo/worktree association and a stable associated Bridge destination. File-opening requests from that terminal go to that Bridge; the browsing source may differ. |
| S19 | “open files should be from anywhere ... only for files, not for review ... files and annotations that we're saving ... save the path ... know what files are open so we can go back to them” | Local files outside Git are now included in Files and saved annotations. Opened-file locations and the ability to revisit them are required. This supersedes S6 for Files. |
| S20 | “Can the agent, using IPC, or the user, using UI, add it to the workspace? That would be ideal.” | Users and agents can add existing Git worktrees to the browsing collection independently of terminal CWD. S23/S24 later narrow this PR to known worktrees in the receiving Bridge; shared collection mutation is excluded. |
| S21 | “the separation and what's open ... show what's actually open, that's not in the repo file tree, need to be more clear” and “drawer design remains separate” | Opened files and worktree-tree membership must be distinguishable; miscellaneous files remain visible/revisitable. Drawer presentation remains a separate design. |
| S22 | “we can keep the ui out of this and make everything being triggered via command spec for ease of testing” (transcription normalized) | Start with command-spec-driven behavior and testing; new controls/layouts can follow. Existing views still need truthful commanded display. This changes delivery order, not the opened-file/worktree outcomes. |
| S23 | “we cannot add undiscovered worktree, only known” (transcription normalized) | This PR adds only known worktrees. U-BN-05 is superseded; opening an individual file does not register its containing repository. |
| S24 | “Change a shared collection or another Bridge ... this is out of our scope” (transcription normalized) | Shared-collection and other-Bridge mutation are excluded from this PR; no new grant capability is requested. |
| S25 | “make that into an approval later ... notification later ... for now we can just prepare it in Bridge” (transcription normalized) | **Superseded by S38–S41 (2026-09-23).** Kept for history: agent file.open prepared without showing. |
| S26 | “redo all agent session and notifications later with session screen” (transcription normalized) | Sessions-screen, notification and approval work stays deferred; the one exception is the Open view popover (S40, S43). |
| S27 | “the agent might work on a different worktree for any reason ... or another repo if its related for changes in the feature” (annotation, transcription normalized) | Cross-worktree/repository reading is a normal feature-development journey, not only recovery from an agent mistake. |
| S28 | “if the agent links to files, to be able to open them ... in the same bridge view I'm in” and “for file tree can we allow any file to be open? ... different from review” (annotation and chat) | An exact supported local file opens in the receiving Bridge without first selecting or adding its containing worktree. Files and Review have different eligibility rules. |
| S29 | “multiple work spaces in the same bridge, so different git repos should be selectable ... from command spec ... UX later” (annotation, transcription normalized) | Include known-worktree membership and explicit selection in this command-first design. S17's broader deferral no longer excludes these commands; new selectors remain deferred; S32 later includes all member trees in Files. |
| S30 | “use the annotations to edit things and send the agent information back, so I know what the agent's doing” (annotation) | Preserve the annotation feedback loop for all supported documents, including existing copy/export. This does not select automatic agent delivery or source-file editing. |
| S31 | “yes i want the whole system to be cohesive like VS Code workspace” after confirming search across all member worktrees and opened miscellaneous files (transcription normalized) | Collection-wide filename/path search is included; users need not select a worktree first. |
| S32 | “for file we should show all worktrees” and “worktree is removed we unselect the file ... different from one off opened files ... outside the worktrees or not” (transcription normalized) | Files exposes every member tree plus individual files outside members, classified by resolved location. Removing a member clears its displayed file and does not reclassify its files as individual entries. |
| S33 | “yes we can never remove the cwd worktree” in response to next-member Review fallback (transcription normalized) | Removing selected Review membership switches to the next remaining member in collection order and its remembered comparison. The terminal's current known CWD worktree cannot be removed. |
| S34 | “yes” to adding/protecting a newly known CWD worktree, leaving the previous member removable and keeping displayed selections unchanged | Known CWD changes update membership/protection, not Files or Review selection. |
| S35 | “remove”, “only the cwd worktree (if there is one) is protected”, “else it just stays in the list”, and “cwd worktree should be injected into our list” (transcription normalized) | Inject/deduplicate the current known CWD member and protect only it. Without one, no member is protected. Old members remain until explicit removal. With no members, Files retains loose files and Review is empty. |
| S36 | “drawer owner ... we just use that ... pane cwd is what matters ... if a file exists in worktree then its not a loose file” (transcription normalized) | Drawer callers use the owner pane's Bridge. Owner-pane CWD determines protection; caller CWD resolves relative paths. Location within member worktrees determines grouping, not opening method. |
| S37 | “yes remove it” and “we already discussed it” in response to catalog unregistration | Apply the existing membership-removal rule when Agent Studio unregisters a worktree: clear its file, apply Review fallback, preserve annotations. No separate unavailable-member choice for explicit unregistration. |

Owner statements on 2026-09-23 (orchestrator session f4ba41d2; full record in
the [workspace IPC control Requirements](../../../../agent-studio.ipc-improvements/docs/specs/2026-09-23-workspace-ipc-control/requirements.md),
owner statements S1–S29 there):

| Source | Owner statement | Meaning carried forward |
| --- | --- | --- |
| S38 | “The agent wants us to show a screen; it should show a file and be able to do that.” | Supersedes S25: agent file open is no longer preparation-only. |
| S39 | “It should all show up at the terminal's bridge, so the terminal's bridge should display it.” | The receiver is the terminal's own Bridge (R3 unchanged). |
| S40 | “Load it silently and the notification says 'open view' with a little pop-up so we can click on it. If the bridge is open already we can show it.” | Visible receiver → show; otherwise load silently with an Open view item. Supersedes S26 for this one popover. |
| S41 | “They can open the file… it can be open in the background… to bring to view or to disrupt the user's flow is a separate [step].” | Loading is a background action; revealing is the human's Open. |
| S42 | “…command-click controls to pick up any file link, so that the spacing that's cut off by junk gets fixed… the user can use it.” | ⌘-click paths (including hard-wrapped) open in the terminal's Bridge. |
| S43 | “We would have to use the macOS popup like [Arrangements / Launch bookmarked]”; “if something is immediately actionable, it should be a pop-up.” | Open view is the app's native bottom-bar popover; no toast or Inbox. |
| S44 | “cmd click goes to our view with option to open as default shown in bridge for all files”; “we not gonna have settings in app we use agent to write settings for now through IPC commands with approval.” | Bridge is the ⌘-click default; the alternative is a setting written by an approved agent command. |
| S45 | “Follow app styles and our standards… keyboard-nav navigable. Everything should be through the command spec… use the arrow keys.” | Popovers use AppStyles and are fully keyboard navigable through catalog commands. |
| S46 | “The PR should be summaries… in the main [bar] it should just show if it's going well or not, and then the pop-up should show the details”; multi-repo work “should be its own work tree”. | Multi-member PR summary button + details popover (B3); the Bridge stack is its own worktree. |
| S47 | On the revised Bridge design's new components (runtime Open view items, `PaneOpenViewPresentation`, `TerminalFileLinkResolver`, multi-member PR fold, one ⌘-click preference key): “it's fine.” | Structural realization of B1–B3 confirmed by the owner (2026-09-23). |

Current source establishes what exists, not which alternative the owner has
chosen. The [current-path evidence](./2026-09-12-proposal-and-tradeoffs.md#what-the-app-already-provides)
corrects the initial “no IPC” description without removing the desired outcome.

## User requirements

Active rows below have producer-owned authority state **authorized**: their need
and scope come from the cited owner statements. The producer is the Agent Studio
owner; this document normalizes those statements. Relative delivery priorities
are **unranked; owner has not assigned an order**. U-BN-05 is explicitly
superseded by S23 and retained for traceability. Recommendations in the proposal
are not priority assignments or authorization to implement.

| ID | Affected class | Need or outcome | Why it matters | Authority / evidence |
| --- | --- | --- | --- | --- |
| U-BN-01 | Human | Search all member worktrees and opened miscellaneous files together, then open a result directly through keyboard/command navigation with a clear location. | Searching commands or repositories alone does not reach the file being discussed. | Authorized, S1/S19/S31; current command-bar scopes are observational evidence. |
| U-BN-02 | Agent / automation developer | Direct the terminal's stable associated Bridge to an intended file (and line) through IPC — shown when that Bridge is visible, otherwise waiting in Open view — or to its Git Review when applicable. | The agent can identify work that the human otherwise has to locate manually; source changes must not redirect requests to another terminal's Bridge. | Authorized, S2/S18/S19/S36, S38–S41 and the original request for Bridge command/IPC control. |
| U-BN-03 | Human | Read files linked by the agent in the same receiving Bridge, including another worktree or related repository and full-screen reading, while the terminal continues. | Feature work can span locations for any reason; opening an exact file must not first require browsing-root selection. | Authorized, S3/S5/S27/S28. |
| U-BN-04 | Human | Keep Git review and annotations meaningful when navigating between files and worktrees, and give the agent correctly located annotation feedback through the existing copy/export workflow. | A convenient navigation path is not useful if it presents the wrong comparison, loses feedback, or labels comments as belonging to another file. | Authorized, S4/S5/S30; draft settlement must preserve original text/source; its mechanism belongs in Program Design. |
| U-BN-05 | Human and agent | Superseded for this PR: undiscovered Git repository/worktree intake is excluded. Individual files at those paths remain openable as local documents. | File opening does not require registration of its containing worktree. | Owner-authorized supersession, S23; file coverage remains U-BN-13. |
| U-BN-06 | Human and agent | Move between relevant files and File/Review surfaces through discoverable controls. | Entry into Bridge should not leave the user at a navigation dead end. | Authorized, original request about moving between file-mode functions and S1/S2; the precise control inventory is proposed. |
| U-BN-07 | Human | Keep Bridge out of drawer content and prevent dragging Bridge into ordinary pane layouts, while allowing a Bridge tab to own a drawer. | A rich reading surface and its supporting tools are different things; one restriction must not remove the useful inverse relationship. | Authorized, S8/S15. Other mixed-layout creation/restore routes remain an explicit policy question. |
| U-BN-08 | Human | Moved without changing identity to [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md#user-requirements). | Dedicated drawer track; no need removed. | Authorized; see S9–S15 in the source record above. |
| U-BN-09 | Human | Moved without changing identity to [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md#user-requirements). | Dedicated drawer track; no need removed. | Authorized; see S9–S15 in the source record above. |
| U-BN-10 | Human | Moved without changing identity to [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md#user-requirements). | Dedicated drawer track; no need removed. | Authorized; see S9–S15 in the source record above. |
| U-BN-11 | Human | Moved without changing identity to [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md#user-requirements). | Dedicated drawer track; no need removed. | Authorized; see S9–S15 in the source record above. |
| U-BN-12 | Human | Moved without changing identity to [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md#user-requirements). | Dedicated drawer track; no need removed. | Authorized; see S9–S15 in the source record above. |
| U-BN-13 | Human and agent | Open and read local files outside any Git worktree in Files, with annotation support. | Agents produce notes and other material in miscellaneous directories; a missing worktree must not make those documents unreadable. | Authorized, S19; supersedes the Files-only part of S6. |
| U-BN-14 | Human | Save opened-file locations and annotation associations, and revisit those documents. | A file shown once by an agent must remain findable even when it is outside the repository tree. | Authorized, S19. The command-first contract retains missing entries; new closed-file history and moved-file UI are deferred. |
| U-BN-15 | Human and agent | Manage known worktree membership through commands, browse/search all members in Files, and select one member for Review. Protect the current known CWD member; remove other members with explicit file-clear and Review fallback behavior. | One task can involve multiple known worktrees or repositories. | Authorized, S20/S22/S23/S24/S29/S32/S33/S34/S35/S37. New UI entry controls may follow; shared/other-Bridge mutation is excluded. |
| U-BN-16 | Human | Clearly distinguish opened documents from worktrees/folders available for browsing. | Miscellaneous open files must not disappear from the user's navigation merely because they are absent from the selected repo tree. | Authorized, S21. Open Files and a worktree selector/tree are proposed presentation, not selected control geometry. |

## Boundary

**Established by the owner:** this is Agent Studio's Bridge navigation and
reading/review workflow; it includes humans and agent callers, multiple known Git
repos/worktrees, arbitrary local files, keyboard/command entry, and continued
use of annotations. It also includes normal/full-screen drawer presentation,
top-resize reliability, and the explicit placement restrictions in U-BN-07.
Ordinary local files outside Git are included in Files and file annotations by
S19. Git Review still requires a Git worktree and comparison. Opening a file does
not imply recursively indexing its containing directory or adding it as a
workspace root.

**Drawer track:** the selected geometry, resizing, ownership and side behavior now
have one home in [Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md).
The drawer track can proceed independently of Bridge source selection and
multi-worktree membership. U-BN-08–U-BN-12 are retained at that dedicated home.

**Source and navigation tracks:** a terminal's associated Bridge is the stable
receiver. Files can display a local document independently of Git Review or
browsing membership. File navigation supplies search, exact-file opening,
File/Review switching and reliable destination arrival. S29 includes known-worktree
membership and selection commands in this design. S31/S32 additionally require
collection-wide search and all member trees in Files. New picker/control design
remains deferred; displaying only one member tree no longer meets the outcome.
Exact-file opening does not depend
on adding a worktree or implementing a multi-root tree. Review selects one known
worktree and its own comparison at a time, including in fullscreen. Cross-worktree
Git comparison is not introduced.

**Settled association:** one current terminal CWD supplies one resolved
repo/worktree association. Initial Bridge context is seeded from that terminal.
Requests from it use the same associated Bridge as files and browsing roots
change. This does not freeze the shell’s CWD value. The owner’s earlier
“cwd is the terminal cwd” and explicit Bridge-source-switching direction,
confirmed by S18, separates later CWD observations from explicit Bridge
navigation state. The current known CWD worktree is included and protected from
removal. A transition to another known worktree adds/protects that member and
leaves the previous member removable, without changing Files or Review selection.
When CWD resolves to no known worktree, or the Bridge has no associated terminal,
no member is protected. Existing members remain until explicitly removed. With
no members left, Files retains loose files and Review is empty (S35).

Drawer-terminal requests use the owner pane's Bridge (S36). The caller's CWD
resolves a relative path, while the owner terminal's CWD determines protected
membership. A drawer CWD change does not inject or protect another member.
Files already under a member worktree are shown under that worktree.

**Command-first delivery:** S22 allows new UI controls/layouts to follow the
native behavior. The first surface is typed command-spec execution, including
debug IPC testing. Human UI and agent capabilities remain the overall outcomes;
no selector layout is selected by this delivery choice. IPC v2 transport/catalog
and v1 retirement are owned by the agent in `agent-studio.ipc-improvements`;
Bridge behavior must integrate with that work instead of creating parallel v1
methods or another command catalog. Exact integration and authority differences
are recorded in the separate research/coordination material.

**Agent opening behavior (S38–S41, superseding S25):** agent file.open retains
the file in the associated Bridge and shows it at the requested line when that
Bridge is visible and no draft is open; otherwise it loads silently and an Open
view item appears in the owner pane's native bottom-bar popover, which the human
opens (S40, S43, S45). It never takes focus or enters fullscreen by itself.
Sessions-screen redesign, notification history and approval flows stay
deferred (S26); the Open view popover is the one exception.

**Foundation to preserve:** existing File and Review experiences, meaningful Git
comparison identity, annotation ownership, and command-based interaction. The
current distinction between a terminal-following companion and an independent
Bridge is evidence to weigh, not an owner decision that it can never change.

**Proposed limits for review:** no terminal relocation merely to browse other
files/worktrees; no file editing, Git mutation, repository cloning/worktree
creation, remote filesystem access, or automatic annotation transfer between
unrelated documents. Adding an existing worktree to a collection is different
from creating it on disk. Non-Git file annotation support is included; a general
filesystem explorer or search of every local directory is not implied.

**Deferred presentation/extension choices:** new collection controls and
Command-P UI/bindings, broader filter/display controls, moved-file reconnection
UI and closed-file recents. Files must still expose all member worktrees together.
The command-first specification protects drafts during activation; these extension choices do not
block its backend contract. These questions must not reopen
the settled receiver or exclude ordinary local files. Undiscovered-worktree
intake and shared/other-Bridge mutation are excluded, not pending decisions.
Mixed-layout restrictions beyond dragging and treatment of existing saved layouts
remain with the separate placement track. Temporary source unavailability retains
an unavailable member; explicit catalog unregistration applies the settled
Bridge membership-removal behavior (S37).
Full-screen drawer side defaults and hidden-region fallback are settled in the
dedicated Drawer Presentation Requirements.
No vendor/package expansion is requested or authorized by these documents.

## Journeys to improve

### Human: reach and review the agent's work

```text
Agent points to an exact file                               U-BN-02, U-BN-03
  → prepare its path; human explicitly activates it
    Desired: read it in the same receiving Bridge, including fullscreen
    No worktree membership or Review selection is required
  → annotate it and copy/export feedback                    U-BN-04, U-BN-13
    Desired: comments identify this file, even outside Git
  → optionally browse more files or inspect Git changes     U-BN-01, U-BN-15
    Add an already-known backend/frontend worktree if needed
    Choose Files browsing OR choose Review's worktree + comparison
  → return to the exact file from opened documents          U-BN-14, U-BN-16
    Keep terminal CWD, saved feedback and the receiving Bridge
```

The observed pains are grounded in evidence E1–E5 in the proposal. The desired
steps separate exact-file reading from repository browsing. A link supplies a
destination: ⌘-clicking a file path in the terminal opens it in this Bridge
(S42, S44), and agents open files through the same owner (S38–S41).

### Human: switch Review between related worktrees in fullscreen

```text
Terminal stays in backend/main                             U-BN-03
  → same Bridge retains backend/feature and frontend/feature U-BN-15
  → explicitly Review frontend/feature against its baseline U-BN-04, U-BN-06
  → switch Review to backend/feature; preserve pending drafts
    Desired: show backend's complete comparison in that same Bridge region
  → return to frontend Review and its retained comparison
  → return to Files and the independently retained document U-BN-14, U-BN-16
```

Fullscreen affects presentation, not worktree membership or selection ownership.
There is no combined backend/frontend diff. Existing annotation copy/export gives
the human feedback to hand to the agent, as in the annotation batch used to review
this document. Saving or copying does not itself prove agent delivery or receipt.

### Agent: open an exact file for the human

```text
Identify file (and line)                                     U-BN-02, U-BN-13
  → request file open
    Today: open creates a new tab and reveal is a second call
  → Bridge visible and no draft open → shown at the line     U-BN-02, U-IC-03
  → otherwise → loaded silently, Open view item in the pane's bar
    Desired: focus, fullscreen and the current read unchanged
  → human chooses Open (keyboard or click) → Bridge revealed, file shown
  → the agent receives shown, waiting in Open view, or a specific failure
```

Evidence E3/E6 in the proposal supports this sequence; S38–S41 select it
(superseding S25).

### Human: ⌘-click a path in the terminal

```text
Agent prints a path (maybe hard-wrapped with padding)        U-IC-06
  → human ⌘-clicks it
  → the file is shown at its line in this terminal's Bridge, revealed if hidden
  → non-file links still open in the browser; a bad path opens nothing
```

### Human and agent: miscellaneous files alongside worktrees

```text
Agent in terminal A opens /tmp/task-notes.md (Bridge hidden) U-BN-02, U-BN-13
  → A’s associated Bridge retains it; an Open view item appears
  → human chooses Open; the file and its location are shown
  → user annotates it; the opened-file entry remains findable U-BN-14, U-BN-16
  → a command/IPC adds a known frontend worktree             U-BN-15
  → user browses frontend and requests its Git Review
  → user returns to the notes through opened-file navigation U-BN-14, U-BN-16
```

The notes do not require a Git worktree, and adding frontend does not move
terminal A or imply moving the notes' annotations into frontend's Review.

Drawer journeys and proof for U-BN-08–U-BN-12 have their single home in the
[Drawer Presentation Requirements](../2026-09-13-drawer-presentation/requirements.md).

## Evidence of a useful outcome

The owner's repository instructions require real-path behavior and visual proof
where UI composition matters. Applied here, proposed acceptance evidence is
an authorized agent/IPC journey that opens the exact file in A’s associated
Bridge — shown at the line when visible, otherwise waiting in Open view without
changing focus, fullscreen or the current read — followed by the human's Open
proving displayed arrival, plus native ⌘-click and keyboard-navigable popover
journeys (S42–S45). The
human can verify a known worktree B’s Git context, use existing annotation
interactions, and navigate onward while terminal A remains in place. Include
another known Git worktree and an ordinary local
file outside Git, with saved location/annotation restoration and a truthful
non-applicable Review outcome for that file. Prove known-worktree add/select/inspect
through typed commands and IPC, distinguish browsing membership from opened
files, and prove return to a miscellaneous document after browsing another
worktree. Real rendered activation, annotation, Open view, ⌘-click and
multi-PR popover proof is required; Command-P and new selector UI remain later
work. Wire integration follows IPC v2 and the IPC control A1 rule. No implementation evidence is
claimed here.

