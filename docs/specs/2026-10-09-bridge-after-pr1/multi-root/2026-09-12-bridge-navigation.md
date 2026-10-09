# Bridge Files and Worktree Navigation — Command-First Specification

[Requirements](./2026-09-12-requirements.md) → this Specification →
separate Program Design. [Tradeoffs](./2026-09-12-proposal-and-tradeoffs.md)
explain alternatives; they do not override the selected owner decisions.

This specification covers the Bridge stack. The
[drawer specification](../2026-09-13-drawer-presentation/specification.md) owns
drawer behavior; the [workspace IPC control specification](../../../../agent-studio.ipc-improvements/docs/specs/2026-09-23-workspace-ipc-control/specification.md)
(layer A1, sibling checkout `agent-studio.ipc-improvements`) owns which commands
pane agents may run. New pickers, selectors, Command-P UI, Sessions screens,
notification history and approval prompts are deferred. Files still exposes all
member worktree trees together. Existing Bridge rendering and annotation
controls remain the display foundation.

Owner decisions of 2026-09-23 (Requirements S38–S46) supersede the earlier
preparation-only agent contract (S25/S26): an agent-opened file is shown when
the terminal's Bridge is visible, and otherwise loads silently with an Open view
item the human acts on.

**Delivery layers.** B1 — the stable receiving Bridge per terminal, membership,
search, Files/Review separation, local documents, opened-file inventory (R1–R4,
R14–R16, C1–C4, C7). B2 — opening files for the human: agent open, ⌘-click and
the Open view popover (R5, R17, R18, C5). B3 — the multi-PR summary (R19). A1's
own-pane rule gains the receiver as part of an agent's own pane in B1.

## Observable model

```text
Agent in terminal A → open file (path, line) → A's receiving Bridge inventory
     receiver visible, no unfinished draft  → shown at the line
     otherwise                              → loaded silently + Open view item
Human ⌘-clicks a path in terminal A        → shown in A's receiving Bridge
Human chooses Open in A's Open view        → receiver revealed, file shown

Known worktrees → browsing membership → all member trees in Files
Local file path → opened-file inventory → file reading and annotations
Git Review     → one known worktree and one comparison

Known terminal CWD → included/protected member; displayed selections unchanged.
No repository registration is performed.
```

Loading a document, browsing membership and visible activation are separate
effects.
Each receiving Bridge has its own state. A terminal’s current context seeds its
associated Bridge; the stable receiving identity is the terminal pane, not a
replaceable native companion instance. A standalone Bridge tab is its own receiver.

## R1 — Resolve the exact destination

A File command MUST resolve its actual local file location. Relative paths MUST
have a captured base directory; an admitted request MUST NOT be reinterpreted
against later focus or CWD. The CLI may supply its process CWD so agents do not
manufacture repository/worktree IDs. Missing, inaccessible or non-file paths MUST
receive a specific refusal, without an unrelated fallback destination.

Git membership and Review MUST resolve already-known worktrees. A file in an
unknown repository remains eligible as a local document; opening it MUST NOT
register its repository or invent a worktree identity. Existing supported-content
classification remains authoritative: no new binary/encoding renderer is implied.

Basis: U-BN-02, U-BN-03, U-BN-13, U-BN-15; S23. Contract C1. Proof V2/V5/V13.

## R2 — Search through explicit command scope

A search command MUST search the receiver's member worktrees and opened
miscellaneous files together without first selecting a worktree. Explicit
narrowing to opened files or a member worktree MAY remain available. Results MUST
identify the actual file location and worktree where applicable, distinguish
same-relative-path files in different worktrees, and avoid duplicate results for
the same resolved file. A failed member query MUST be identified alongside results
from successful members; partial coverage MUST NOT be presented as a complete
empty result. Search MUST NOT activate a result, add roots or crawl
arbitrary directories outside members. Invalid/unavailable scope MUST remain
distinguishable from no matches. New Command-P controls remain later work;
collection-wide filename/path search is part of this slice.

Basis: U-BN-01, U-BN-06; S22/S31. Contract C2. Proof V1/V6.

## R3 — Keep the receiving association stable

Terminal-agent commands MUST target that terminal’s associated Bridge even when
the requested file is outside its CWD/worktree. Commands MUST NOT redirect to a
Bridge merely because it already displays that worktree. Native resource
replacement, hiding and leaving fullscreen MUST NOT change the logical receiver
or lose its retained documents. Explicit standalone-Bridge commands target that
Bridge. A drawer-terminal caller MUST resolve to its owning pane's Bridge:
the owner's associated Bridge for a terminal owner, or that Bridge pane itself
for a Bridge owner. Relative paths MUST resolve against the caller's captured
CWD; protection MUST use the owner terminal's current known CWD worktree.
Drawer CWD changes MUST NOT inject/protect members of the owner's collection.
The owned drawer relationship supplies the destination; arbitrary other-pane or
shared-collection targeting remains excluded. A caller whose owner has no Bridge
receiver MUST receive an explicit unsupported-target result, not a guessed receiver.

Initial context comes from the terminal's known worktree when available. The
current known CWD worktree MUST belong to the collection and MUST NOT be removable.
When CWD resolves to another known worktree, Bridge MUST add it if absent and
protect it, leaving the former CWD member removable. It MUST retain opened files
and Files/Review selections. Moving the shell does not select new displayed
content, and changing Bridge membership does not move the shell. When CWD has no
known worktree, or the Bridge has no terminal association, no member is protected.
Previous members MUST remain listed until explicitly removed; protection MUST NOT
remain attached to the last known CWD member.

Basis: U-BN-02, U-BN-03; S18/S24/S36. Contract C3. Proof V2/V3.

## R4 — Separate Files from Git Review

Files MUST be able to display a supported local document regardless of whether
it appears in a Git comparison or the selected worktree tree. Exact-file opening
MUST NOT require adding or selecting the containing worktree. Review MUST use
one known worktree and its chosen comparison. Opening one review file MUST NOT
turn the complete comparison into a single-file package.

The selected Files scope/document and selected Review worktree/comparison MUST
be independent. A command changing one MUST NOT silently change the other.
Switching Review between member worktrees MUST retain each worktree's comparison
choice. Fullscreen uses those same selections in the same associated Bridge;
changing Review MUST NOT relocate the terminal or open another Bridge tab.

If a file has no eligible known-worktree Review, or is absent from the chosen
comparison, the result MUST identify that condition. It MUST NOT silently switch
comparison, use an unrelated selected worktree, or claim Files as successful
Review arrival. Choosing another worktree MUST NOT reuse a comparison belonging
to a different repository. Existing per-worktree comparison semantics remain.

Basis: U-BN-02, U-BN-04, U-BN-06, U-BN-13. Contract C4. Proof V4/V6/V13.

## R5 — Agent opens a file for the human (B2)

An agent's file open names a path (absolute, or relative to its captured CWD)
and an optional line. The document MUST be admitted and retained in the
caller's receiving Bridge (R3). Then:

- **Receiver effectively visible and no unfinished draft in its current
  document:** the document MUST be shown at the line. Effectively visible means
  the human can currently see it: its window is visible and not minimized or
  occluded, its tab is selected, and (for a terminal's Bridge) Pane Zoom shows
  it. Visibility is rechecked before the document is shown.
- **Otherwise:** the document MUST load without changing what the human sees —
  no fullscreen entry, window activation, keyboard focus change or replacement
  of the displayed document — and an Open view item for it MUST appear in the
  owning pane's Open view popover (R18). Loading MUST work without a mounted
  Bridge view.

The caller MUST distinguish shown, waiting in Open view, failed, refused, not
yet allowed and uncertain outcomes. Shown means the exact document at the line
was displayed (see C4 arrival); waiting means admitted and retained. Content
availability is reported separately. Repeating the open of the same resolved
file MUST NOT duplicate its opened-file entry, its Open view item or discard its
annotations; the line is updated.

Human activation (Open in the popover, or ⌘-click) MUST distinguish loading from
actual displayed arrival. A created native view, issued command or selected row
alone MUST NOT establish arrival.

Basis: U-BN-02, U-BN-14, U-IC-03; S38–S41. Contract C5. Proof V2/V3/V14.

## R6 — Preserve annotation meaning

Saved and unfinished annotations MUST remain associated with their original
document/source when preparing or activating other files. Preparation MUST NOT
navigate away from an active edit. Non-Git file annotations MUST NOT require
synthetic Git IDs. Existing Git review provenance/continuity remains intact.

If deliberate activation cannot preserve the current unfinished draft, it MUST
refuse or remain pending with the prior document intact; it MUST NOT silently
lose text. The precise draft-settlement mechanism belongs in Program Design.
Changed/missing content MUST produce truthful exact/relocated/outdated/unavailable
placement as applicable, rather than presenting an old anchor as unquestionably
current. Automatic cross-file annotation transfer is outside this slice.

Existing annotation copy/export MUST remain usable for both Git and ordinary
local-file subjects, with the actual document location, source excerpt/placement
and saved feedback. Output for an ordinary file MUST NOT label it as belonging to
the selected Review worktree. Existing editing/output rules still apply. Saved,
copied or exported feedback MUST NOT be reported as delivered to an agent merely
because that operation succeeded; automatic delivery is not introduced here.

Basis: U-BN-04, U-BN-13, U-BN-14. Contract C4/C7. Proof V4/V13/V14.

## R17 — ⌘-click a file path (B2)

When the human ⌘-clicks a file link in terminal A — an OSC 8 `file://` link, a
plain path on one row, or a plain path whose remainder is on the next row after
a hard wrap — the path MUST resolve against A's current CWD and the document
MUST be shown at its line in A's receiving Bridge, revealing that Bridge if it
was not visible (the human asked directly). R6 draft protection applies. By
default ⌘-clicked files open in the Bridge; a setting can send them to the
system default app instead, and that setting is changed by an agent through an
approved IPC command (IPC layer A2), not a settings screen. Non-file links keep
opening outside the app. A path that does not resolve to a readable file MUST
NOT open anything. No change is made to Ghostty or other vendored projects.

Basis: U-IC-06; S42, S44. Proof V16.

## R18 — Open view popover (B2)

Each pane with waiting agent-opened files MUST show a button in its bottom icon
bar with the waiting count, opening the app's native popover anchored to that
button — the same mechanism and styles as the pane note and "Launch
bookmarked" popovers (AppStyles, shared shell controls). Rows list waiting
files with location and line. Arrival MUST NOT take keyboard focus or open the
popover by itself. The popover MUST be fully keyboard navigable: arrow keys
move between rows, and keys open, dismiss and clear all. Open, dismiss and
Clear all MUST be catalog commands with labels and shortcuts from the command
spec; their agent eligibility is not yet allowed. No toast, banner, window
alert or Inbox entry is created.

Basis: U-IC-07, U-IC-11; S40, S43, S45. Proof V17.

## R19 — Multi-PR summary (B3)

When a receiving Bridge has several member worktrees, the owning pane's bottom
bar MUST summarize their pull requests in one button. The count is the number of
members whose pull request needs attention (checks failing or changes
requested); the button shows "needs attention (N)" when N > 0, otherwise
"running" when any member's checks are running, otherwise "all good" when at
least one member has a pull request with passing checks, otherwise "no PR info"
(every member has no pull request or unknown facts). Members with no pull
request, or whose facts have not been fetched yet, appear in the popover as
"no PR" or "unknown" and never count as good or bad. Facts for every
member MUST be kept current while the summary is visible, even when no other
pane shows that member. The native popover lists each member with its pull
request number and check state and follows R18's keyboard and command rules;
opening a pull request from a row is a catalog command. The single-worktree
case keeps today's pull request control. (Count meaning is the orchestrator's
default pending owner review — parked item 1.)

Basis: S46. Proof V18.

## R7 — Use one command contract and inspectable outcomes

Every new user-visible action MUST have one command-spec identity, typed inputs,
authority classification and observable result. UI, IPC and test drivers MUST
invoke that semantic owner rather than parallel implementations. Queries MAY
use the existing read-only snapshot/catalog boundary without inventing a command
identity for each field. Inputs MUST name selections that future UI controls
would otherwise supply; debug execution MUST NOT wait on a picker. B1's new
typed operations are command-spec/IPC entry points without new command-bar
rows or pickers; the B2/B3 popovers' actions MUST carry catalog shortcuts
(R18, R19). Existing human controls remain. Collection search uses the receiving
Bridge's mounted worker; an unmounted or unready receiver returns an explicit
unavailable/not-ready result without creating or activating a viewer. Loading a
file (R5) remains independent of viewer mounting.

IPC v2 owns transport, schemas/registry, target/auth, generated CLI and
correlation. This slice MUST contribute to that boundary and MUST NOT add v1
methods, another parser, operation journal or grant system. Which commands a
pane agent may run follows the workspace IPC control specification: from B1 the
caller's receiving Bridge is part of its own pane, so its Bridge reads, in-Bridge
navigation and file open are own-pane commands on every channel; revealing the
Bridge, Open, dismiss, Clear all, membership removal and settings changes are
not agent commands in this stack. Debug availability does not create
production-agent authority.

Basis: U-BN-01, U-BN-02, U-BN-06; S22/S24. Contract C5. Proof V2/V6.

## R8 — Preserve Bridge placement boundaries

This slice MUST NOT place Bridge inside a drawer or implement preparation by
creating a separate tab per file. A normal Bridge tab retains its own drawer.
General drag/creation/restore policy enforcement is a separate placement track;
this source retrofit does not delete existing layouts to enforce it.

Basis: U-BN-07. Contract C6. Proof V7.

## R9 — Normal drawer resizing

Owned by R-DP-1 in the [drawer specification](../2026-09-13-drawer-presentation/specification.md).

## R10 — Fixed fullscreen overlay

Owned by R-DP-2 in the [drawer specification](../2026-09-13-drawer-presentation/specification.md).

## R11 — Selected-side width and gutter

Owned by R-DP-3 in the [drawer specification](../2026-09-13-drawer-presentation/specification.md).

## R12 — Drawer presentation and ownership

Owned by R-DP-4/R-DP-5 in the [drawer specification](../2026-09-13-drawer-presentation/specification.md).

## R13 — Drawer geometry consistency

Owned by R-DP-6 in the [drawer specification](../2026-09-13-drawer-presentation/specification.md).

## R14 — Ordinary local documents

Accessible supported local files outside Git MUST be readable and annotatable
through the same Bridge Files experience. Their saved location MUST identify
the document independently of a repository tree. Opening one file MUST NOT
implicitly authorize enumeration of its containing directory. A local file in
an unknown Git repository follows this same document path; its Git Review is
unavailable until that worktree is known through a separate app workflow.

Basis: U-BN-13, U-BN-14. Contract C1/C7. Proof V13.

## R15 — Retain and inspect opened files

The receiving Bridge MUST maintain an ordered, inspectable opened-file inventory
with exact locations, preparation/availability state and current selection.
Documents from equal basenames or different worktrees MUST remain distinguishable.
Prepared files MUST remain activatable independently of an optional browsing
filter, subject to explicit membership-removal behavior in R16.

Opened locations and selection MUST survive ordinary app shutdown/restoration
of the same receiving owner. This is path/state retention, not file-content
archiving. A restored missing document MUST remain identifiable as unavailable;
its annotations MUST NOT be deleted. Closing an opened-file entry removes it
from that receiver’s open inventory, not from disk or annotation storage.
Closed-file recents, automatic moved-file discovery and new reconnection UI are
outside the command-first slice. Reopening an exact location remains supported.

Basis: U-BN-14, U-BN-16. Contract C7. Proof V14.

## R16 — Manage known-worktree membership

A typed command MUST add an already-known worktree to the receiving Bridge’s
ordered browsing membership without changing terminal CWD, another receiver or
the shared repository catalog. Duplicate addition MUST have no duplicate effect.
Unknown worktrees MUST be refused without discovery/adoption/registration.

Files MUST expose all member worktree trees and individually opened files
outside those members together. Classification MUST use resolved location, not
how the file was opened. Explicit Files filtering does not redefine membership.
Review MUST select one member plus its retained or requested comparison.
Adding membership alone MUST NOT replace an ongoing read.

A removal command MUST refuse removal of the current known CWD worktree. For
other members it MUST remove the tree and clear any displayed Files document
belonging to that member. Those files MUST NOT automatically reappear as
miscellaneous files after removal. Unrelated individual files and saved
annotations MUST remain intact. Explicitly reopening an exact file afterward
remains supported; membership removal never deletes disk content or unregisters
the worktree from Agent Studio.

If Review selected the removed member, it MUST switch to the next remaining
member in collection order, wrapping to the first when needed, and restore that
member's comparison choice. With no remaining members, Review MUST be empty and
Files MUST retain unrelated individually opened loose files. Draft preservation under R6 applies before removal
can clear content or switch Review; failed settlement leaves the removal pending
or refused. Temporary catalog/path unavailability is not explicit unregistration and MUST
NOT silently trigger fallback. When Agent Studio explicitly unregisters a
worktree, Bridge MUST apply the same member-removal, file-clear and Review-fallback
rules in every receiver containing it, preserving annotations. No registration or
CWD-protection fallback may re-add the unregistered worktree. This follows the
existing catalog mutation; it does not grant a pane agent general cross-receiver
control. Draft preservation under R6 still applies before discarding displayed
content; an already-committed catalog mutation must not be reported as rolled back
if Bridge draft settlement remains pending.

Basis: U-BN-15, U-BN-16; S22–S24/S32–S35/S37. Contract C7. Proof V5/V15.

## C1 — File admission

A request carries its receiving target and a path with captured relative-path
base where needed. The native app determines document location and applicable
known Git context. A file path cannot silently override an explicitly conflicting
worktree target. Exact-file admission and descriptor/content validation remain
required, including symlink/race handling; broad filesystem access is not granted
to the web renderer merely because it has a file path.

Initial invalid/missing file requests are refused without an unrelated entry.
Restored entries that later become missing remain unavailable records under R15.
Unsupported content is reported using the existing viewer’s classifications;
this slice does not promise new renderers or searchable contents for every format.

## C2 — Search scope

Filename/path search defaults to all member worktrees plus opened miscellaneous
files; callers can explicitly narrow it to one member or opened documents.
Search results carry the same location identity that
preparation/activation uses. Root/tree filtering follows the existing worktree
source policy; an explicit local file can still be prepared independently of
whether that file is included by a browsing filter. Cancellation and stale query
results MUST NOT activate a document or change the newer selected scope.

## C3 — Receiver and presentation lifetime

Terminal ownership is stable through native view recreation. Hiding Bridge or
exiting fullscreen does not discard prepared documents or membership. Showing
Bridge is a presentation operation; selecting a prepared document is an explicit
activation operation. Preparation does not queue a later forced presentation.

The known terminal worktree seeds initialization and remains protected while it
is the current known CWD association. Later known-CWD changes update membership
and protection under R3 without replacing either selection. Protection is an
observable consequence of terminal association, not a user-managed second CWD.


## C4 — Activation and Review

Activation names a prepared document, or a known worktree/comparison and optional
review file. It reports displayed arrival only for that exact requested source.
For a non-Git or unknown-worktree document, Review returns unavailable while
Files remains usable. Switching worktree/comparison preserves the old context
until the request can safely apply or exposes an explicit loading/failure state;
old content is never labelled as the new source.

Draft protection in R6 applies before replacing source resources. No new prompt
or approval UI is required: inability to settle a draft is an explicit pending
or refused activation, and the old document remains usable.

## C5 — Agent file open on the wire

Agent file open is one IPC method with inputs: caller (implicit "self"), path,
optional captured CWD for relative paths, optional line. It has no placement,
tab, split, drawer or focus inputs; the receiver is always the caller's
receiving Bridge (R3). Results: shown (with the displayed location and line),
waiting in Open view, failed (unreadable, unsupported, no receiver), refused,
not yet allowed, uncertain — using v2's correlation and result/error
framework. A native state mutation and an actually shown document MUST remain
distinguishable in result and snapshot data.

Cancelled or superseded work MUST NOT later overwrite a newer document
selection. Agent IPC v2 has no control replay journal: a lost response is
uncertain, and a retried open may show the file again; the opened-file
inventory and Open view still hold one entry per resolved file. This feature
adds no offline queue, notification ingress or operation store. It replaces
the reserved `file.open` placement contract in Agent IPC v2 C7 (drawer / split
/ tab / new / focus fields); the dedicated `openFile` command identity stays.

## C6 — Separate drawer and placement tracks

R9–R13 retain trace identity while the dedicated drawer specification owns their
behavior and proof. R8 constrains new source-opening routes. General existing
mixed-layout/drag restoration changes are not part of this command-first slice.

## C7 — Inspectable state and persistence

Read-only inspection MUST distinguish receiver identity, all member worktrees, their current removal protection, optional Files filter,
independently selected Review worktree/comparison,
opened documents/locations, active document or Review context,
preparation/availability, and actual presentation state. A caller must
be able to prove that preparation did not change focus or displayed content.
Future Open Files/worktree UI consumes this same state; it does not define a
second list or source-selection path.

Navigation preferences are associated with their receiving owner. Saved
annotations retain their own document/Git provenance and survive closing an
open-file entry. Normal shutdown/restoration is required; new file archives,
remote paths, automatic renaming/migration and cross-file annotation transfer
are excluded.

## Requirement and proof coverage

| Need | Obligation and contract | Evidence |
| --- | --- | --- |
| U-BN-01 | R2/R7; C2 | V1: collection-wide command search across two worktrees and individual files, equal paths/basenames, deduplication and stale/cancelled query; new Command-P UI deferred by S22. |
| U-BN-02, U-IC-03 | R1/R3/R5/R7; C1/C3/C5 | V2: real v2 command path opens an exact file in the caller’s associated Bridge, or drawer owner’s Bridge, with caller-relative path resolution: effectively visible receiver without draft → shown at the line; hidden, offscreen, unmounted or draft open → waiting in Open view with no focus, fullscreen, displayed-document or protection change; repeated open keeps one inventory entry and one item; a retry after a dropped response keeps one entry (no replay journal); typed refusal and not-yet-allowed outcomes. |
| U-BN-03 | R1/R3/R4; C1/C3/C4 | V3: terminal A continues while an exact file in B is opened without membership (waiting in Open view), then the human's Open shows it in A’s fullscreen Bridge; B can be another worktree or related repo. |
| U-BN-04 | R4/R6; C4 | V4: per-worktree comparison and annotation provenance; unfinished draft protected across activation; local-file and Git annotation copy/export identify the actual source without claiming agent delivery. |
| U-BN-05 | Owner-superseded by S23; R1/R16 | V5: unknown worktree rejected without registration, while its exact local file remains eligible. |
| U-BN-06 | R2/R4/R7; C2/C4/C5 | V6: command open, activation, search and known-worktree/Review selection; existing local controls remain usable. Command-P and selector UI deferred. |
| U-BN-07 | R8; C6 | V7: this route never creates Bridge drawer content or a new tab per file; normal Bridge-owned drawers survive. Existing general placement enforcement remains separate. |
| U-BN-08, U-BN-09, U-BN-10, U-BN-11, U-BN-12 | R9–R13; dedicated drawer specification | Dedicated V-DP-1–V-DP-6 are the sole drawer proof home. |
| U-BN-13 | R1/R6/R14; C1/C4/C7 | V13: real non-Git temporary-file open, activation, saved annotations and explicit non-applicable Review. |
| U-BN-14 | R5/R6/R15; C7 | V14: ordinary restart with opened-file order/selection and annotations; duplicate path, close/reopen, missing/changed file and no content-archive assumption. |
| U-BN-15 | R4/R16; C7 | V15: known-worktree add/remove/select/inspect, explicit catalog-unregistration propagation distinct from temporary unavailability, protected-member refusal, removed-file clearing without miscellaneous reclassification, known-CWD protection transfer with selections preserved, no duplicate or cross-receiver/catalog/CWD effect; frontend/backend Review switches in the same fullscreen Bridge retain their own comparisons and leave Files selection intact. |
| U-BN-16 | R15/R16; C7 | V14/V15 distinguish open documents from browsing membership even when the document is outside the active tree. |
| U-IC-06 | R17 | V16: native ⌘-click on OSC 8, plain, soft-wrapped and hard-wrapped paths from Claude Code and Codex output with relative and absolute paths; non-file links open outside; non-resolving path opens nothing; setting in both positions |
| U-IC-07, U-IC-11 | R18 | V17: native popover capture, count, no focus change on arrival, full keyboard journey (arrows, Open, dismiss, Clear all) through catalog commands; agent calls to those commands return not yet allowed |
| S46 | R19 | V18: two and three member worktrees with mixed PR states; summary state and count; popover rows and keyboard journey; single-worktree control unchanged |

Proof uses the actual native owners, file reads and SQLite where those
interactions matter. Command acceptance/unit arithmetic alone is not rendered
arrival. Existing Bridge native/web composition and real IPC proof remain needed;
Command-P and selector UI are not prerequisites, but the Open view and multi-PR
popovers and ⌘-click are. Applicable repository marker-scoped
performance and source-scrubbing rules remain in force. No implementation or
runtime proof is claimed by this specification.
