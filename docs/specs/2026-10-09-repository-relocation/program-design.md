# Program design: repositories keep their identity when folders move

[Requirements](requirements.md) → [Specification](specification.md) (S1–S16) → this document. Grounded at `cac00e968` (main `584f9992d` merged into `remove-watched-folder`). The agentstudio-git pin is `372fedb0`; no package change. **Status: proposed. It realizes owner decision D1 option A, which is not yet decided.**

## Crux

**1. Which fact proves a move?** Today a checkout is known only by its path:

- `RepositoryLifecycleReconciliation.prepare` matches by path or stored stable key, and otherwise issues `UUIDv7.generate()` (RepositoryLifecycleReconciliation.swift:65-83);
- the package's identity is `common:<canonicalCommonDirectory.path>` (pin `372fedb0`, `GitDiscoveryReadContracts.swift:117-144`).

A move proof needs a fact that survives a rename and does not survive a copy.

| Signal | Survives `mv` | Survives a copy or clone | Cost |
|---|---|---|---|
| **A. Folder identity on the startup volume (proposed)** | yes | no: new objects | Reads only. Startup disk only; other volumes and copy-then-delete stay independent. |
| B. A marker file written into `.git` | yes, also across volumes | yes: copies duplicate it | Writes into user Git metadata, which Sep 11's protected scope excludes. Duplicate markers need their own ambiguity rules. |
| C. Git history, remote or name | yes | yes: clones share it | It would merge independent clones, which M3 forbids. Not offered. |

Evidence for A:

- `VOL_CAP_FMT_PATH_FROM_ID` "implies that object ids on this file system are persistent and not recycled" (`MacOSX.sdk/usr/include/sys/attr.h:212-217`).
- `ATTR_CMN_FILEID` is unique within its mounted volume, and `fsgetpath` resolves a number within one fsid (`man2/getattrlist.2:704-713`; `man2/fsgetpath.2:30-66`). Uniqueness therefore holds per volume *instance*, so E3 binds proof to the mounted startup volume.
- A host probe found the startup volume qualifying.
- Measured on that volume:
  - `mv` kept both folder numbers;
  - `cp -R`, `git clone` and `cp -c` produced new numbers;
  - `fsgetpath` returned the new path after a move, and `ENOENT` after deletion, unprivileged.

**2. Ask, don't infer.** A lookup is the only location evidence (S2). Receipts from other roots (FilesystemActor+WatchedFolderResultApplication.swift:159-174) and earlier scans can be stale, so they are not evidence. The startup volume says where a folder is now.

**3. Keep today's rule wherever relocation would conflict with it.** Relocation is admitted only into a location that no record holds (S3.5). A chain resolves head first. Every conflict keeps Sep 11 R1 exactly: a held destination, a cycle or swap, a replacement at the old path while the original cannot be admitted. That one rule keeps four things true:

- every path is held by at most one record, so UNIQUE keys stay valid (WorkspaceCoreMigrations+GlobalTopology.swift:17-35; RepositoryTopologyReplacement.swift:175-180);
- every simple key move goes into an unused key, which makes the recents move replay-safe;
- no displaced-record state is needed;
- no new merge is introduced in any conflict case.

**4. Same UUID, new path.** These consumers already handle a path change for a preserved ID:

- the lifetime index (RepositoryObservationLifetime.swift:42-66);
- root sync (WorkspaceSurfaceCoordinator+FilesystemSource.swift:560-584);
- the Git projector (GitWorkingDirectoryProjector.swift:413-448, 535-586).

These consumers capture the old location, and need an explicit relocation edge:

- recents, which are keyed by the path-derived stable key (EntityRecencyAtoms.swift:7-40; EntityRecencyStore.swift:89-94);
- Bridge panes, whose controller builds its provider and file authority once from `BridgePaneState.source = .workspace(rootPath:)` (BridgePaneState.swift:48; BridgePaneController+Bootstrap.swift:470-502, 757-778; BridgePaneProductSessionOwner.swift:136, 172-184);
- Zoom companion reuse (WorkspaceSurfaceCoordinator+ZoomCompanion.swift:180-200).

**5. Panes cannot follow by identity alone.** The Ghostty zsh integration reports `$PWD` at every prompt (`vendor/ghostty/src/shell-integration/zsh/ghostty-integration:235-241`), and after a move that path is stale. Ghostty drops OSC 7 from a non-local host (`vendor/ghostty/src/termio/stream_handler.zig:1518-1523`). The true location belongs to the leader of the terminal's foreground process group. That group is `e_tpgid` of the session's terminal leader (`sys/proc_info.h:75-81`). The leader's incarnation comes from the existing `ZmxSessionControlling.observeSessionIdentity` (ZmxSessionIdentity.swift:3-17).

## Components

No new atom, store, table or coordinator is added, and there is no package change. For owner acknowledgement with D1:

- three nullable columns on `worktree`;
- one runtime fact, the terminal correction outcome;
- relocation moves recents before publishing topology.

| Component | Slice | Owns | Change |
|---|---|---|---|
| `StartupVolumeFolderIdentityReader` (new) | Infrastructure/FolderIdentity | Darwin facts only | It decides whether the startup volume qualifies: the fsid and UUID of the volume holding the home folder, plus its capability bits. `identity(of:)` requires the path's fsid to equal the startup fsid and returns the folder number. `locate(number)` uses `fsgetpath` on the startup fsid. Outcomes: `.identified` / `.undefined(reason)`; `.located(URL)` / `.notFound` / `.unavailable`. No Git. |
| `RepoScannerGitDiscoveryClient` | Infrastructure | Package validation into scanner evidence | **Enrollment.** It reads the candidate path's identity before the package read, then the identity of `canonicalWorktreePath` and `canonicalGitDirectory` after. The checkout-folder numbers must be equal and both folders on the startup volume. The result is `ResolvedGitEntry.folderIdentity`; otherwise nil (no proof). It is refreshed at every validation. **Destination validation** (S3.3), `validateRelocationDestination(path, expected: I)`, runs in this order: identity(path) == I.checkout; package read #1 → (W, G), with W == path and the role matching; identity(G) == I.gitDirectory; package read #2 → (W′, G′) == (W, G); identity(path) == I.checkout. A Git-directory retarget between the reads changes G′ and declines. There is no app-side Git parsing; both reads use the existing discovery client. The adapter currently discards G (:51-91). |
| `CheckoutFolderIdentity` (new value) | Core/Models | `volumeUUID`, `checkoutFolderNumber`, `gitDirectoryNumber` | Value type with Equatable and Hashable conformance. |
| Recorded identities | `RepositoryTopologyStore` (Core persistence boundary) | Persisted evidence, which has no observer | The store holds `recordedFolderIdentitiesByWorktreeID` as non-observable state, loaded with the topology. `recordFolderIdentityChanges(_:revision:)` runs in the same MainActor step as `applyRepositoryLifecycleChange` (precedent: `recordReparenting`, :28-31). The store persists them with its topology save, and `captureRepositoryLifecycleInput` reads them. No atom field. |
| Core persistence | Core persistence | `worktree` rows | Additive migration `ALTER TABLE worktree ADD COLUMN`: `folder_volume_uuid TEXT`, `folder_checkout_number INTEGER`, `folder_git_directory_number INTEGER`. The UInt64 values are bit-cast. All three present decodes to an identity; all absent to none; any other combination decodes to none, logs a diagnostic, and is rewritten at the next validation. No CHECK and no trigger. |
| Scan baseline | Core/RuntimeEventSystem/Filesystem | `WatchedFolderScanBaseline` | Carries the recorded identity per checkout. The coordinator resends the baseline when either the membership generation or an identity-change generation advances. Today it resends only on membership change (ScopedTopology.swift:84-89). |
| Folder dispositions | `FilesystemActor`, observation assembly (FilesystemActor+WatchedFolderResultApplication.swift:176-192) | Evidence, not decisions | Each observation gains `recordedFolderDispositions`, detailed below. The I/O runs in `@concurrent nonisolated` helpers. |
| Identity claims | `RepositoryLifecycleReconciliation.prepare` (off-main) | Identity resolution (July TA2) | Claim rounds run before the grouping loop, detailed below. `RepositoryLifecycleChange` gains `relocations` (each tagged simple or chained), `identityChanges` and `recentsKeyBatch`. |
| Relocation effects | `WorkspaceCacheCoordinator+ScopedTopology` (App) | Ordering | Freshness check, then recents durable, then apply, then runtime effects (see Flow). |
| Recents relocation | `ApplicationEntityRecencyAtom.relocateKeys(_ batch)` plus `EntityRecencyStore.flushApplicationAsync()` (:89) | Live recents | An assignment-only key operation. For simple moves it replaces the key; moving an empty source leaves the destination untouched. For chained moves it removes entries under both keys. The store then persists the whole snapshot it already owns, and the coordinator awaits that flush before publication. |
| `WorktreeTopologyDelta` | Core | The topology effect contract | Adds `relocatedWorktrees: [RelocatedWorktreeEntry(id, previousPath, path)]`. |
| Bound-pane remount | `WorkspaceSurfaceCoordinator` (App composition) | E8 rebinding | For each relocated worktree, every Bridge pane whose runtime `worktreeId` matches and whose `.workspace(rootPath:)` equals P1 is rebound in two steps. First, its stored root is updated to P2 through the existing pane content mutation (`WorkspacePaneAtom.updateBridgePaneState`, :247), which is persisted. Then the pane is remounted: `teardownView` (WorkspaceSurfaceCoordinator+ViewLifecycle.swift:459) followed by `createBridgePaneView(for:state:)` (WorkspaceSurfaceCoordinator+BridgeViewLifecycle.swift:7-55), the same path that mounts a restored pane (+NonterminalContentMounting.swift:84). A new `BridgePaneController` builds a new provider and file authority from P2; the old controller and its P1 authority are torn down. A Zoom companion for that worktree is remounted the same way (+ZoomCompanion.swift:271) and keeps its source-pane relationship. Pane identity, layout and persisted Bridge state are kept. No Bridge-internal change; Bridge Lead review is still required. |
| `TerminalTrueLocationReader` (new) | Infrastructure | Reading a process's directory | Input is the zmx session identity: boot ID plus leader incarnation L. The read runs in this order: <br>1. the boot ID equals the current boot, and L matches; <br>2. read L's `e_tpgid` → group G, whose leader F is pid G; <br>3. F is alive, and descends from L through a bounded ppid walk (limit in `AppPolicies`); <br>4. read F's `pvi_cdir`; <br>5. re-read L (same incarnation, same `e_tpgid` = G) and F (same incarnation, same pgid G, same ancestry). <br>Any change, a dead group leader, or a missing ancestry gives `.unsupported(reason)`. Read-only; it never calls retirement or kill capabilities. |
| Terminal location correction (new) | Features/Terminal runtime | The S11 decision | Raw reports keep today's path: admit, publish, acknowledge (GhosttyActionRouter+LocalActions.swift:506-563). The correction is a separate follow-up step. A trigger records the pane's report revision and session token, then reads off-main. The result is applied on MainActor only if both are unchanged. A corrected location is published through the TerminalRuntime CWD route (TerminalRuntime.swift:276-280); the existing association follows. Later identical stale raw reports are equality-suppressed at the accumulator (TerminalLocalActionAccumulator.swift:556-588), so nothing flips. Each correction posts `terminalLocationCorrectionSettled(paneId, trigger, reportRevision, outcome)`, a new runtime fact for owner acknowledgement. Triggers: a raw report naming a missing path; a relocation from P1 (panes under P1); launch (panes whose stored location is missing). No readmission hook and no timer. |

## Folder dispositions: how the observation is assembled (S2)

The `FilesystemActor` builds the set of looked-up records. It starts with:

1. records whose recorded identity equals the identity of an entry at another path in this observation;
2. records under root R whose recorded location is absent from the inventory, or presents another identity.

**Closure (N2):** whenever a looked-up record is located at a path held by another record with a recorded identity, that holder is added to the set. This is bounded by the record count.

For each record in the set, the actor locates its folder and attaches one disposition:

- `.relocatable(entry at P2)`: located at P2 ≠ P1, P2 is inside a current watched root (existing containment: FilesystemPathCanonicalizer.swift:233-247; FilesystemRootOwnership.swift:149-169), and `validateRelocationDestination` admits it;
- `.existsElsewhere`;
- `.notFound`;
- `.unavailable`.

Cached receipts never become dispositions.

## Identity claims in `prepare`

1. **Candidates.** One per `.relocatable` disposition. Drop a candidate when another record holds the same identity (S3.4), or when the role disagrees.
2. **Rounds (S3.5).**
   - Round 1 admits every candidate whose destination no record holds. Those are *simple* moves.
   - Each later round admits candidates whose destination was held only by records admitted in an earlier round. Those are *chained* moves.
   - Rounds stop when nothing changes. Candidates left over are declined: cycles, swaps, and destinations held by a record that does not move.
3. **Apply admitted claims.** For each admitted record C:
   - update its path and name, plus its family's `repoPath` when C is main;
   - clear the absences of C and its family;
   - re-derive the stable keys of C and its family from P2;
   - add (old key → new key, simple or chained) to `recentsKeyBatch`.

   The admitted records and their destination paths are consumed.
4. **Grouping loop.** Unchanged (RepositoryLifecycleReconciliation.swift:65-110) over the remaining entries and records. It skips consumed records and paths. Same-path matching is Sep 11 R1, unchanged.
5. **Identity changes.** Each matched entry refreshes its record's identity. If the refreshed identity is held by another record, that record loses it (one identity, one record).

Re-deriving stable keys is required for three reasons:

- a sticky P1 key would let a later folder at P1 match the moved record (:69-72);
- it would collide with that folder's UNIQUE key;
- it would split recents, which `recordOpened` writes under the current path's key (WorkspaceSurfaceCoordinator+ActionExecution.swift:609-617).

Session IDs are opaque UUIDv7 (ZmxSessionID.swift:4-14), so no session is renamed.

## Flow

```mermaid
sequenceDiagram
    participant FA as FilesystemActor (off-main helpers)
    participant RD as Folder identity reader + discovery client
    participant CC as WorkspaceCacheCoordinator
    participant RP as prepare (off-main)
    participant RC as Recency atom + store
    participant MC as MainActor apply (atom + topology store)
    participant PE as Pane effects
    FA->>RD: scan entries (enrollment identity)
    FA->>RD: locate looked-up records (closed over holders); validate destinations (two reads)
    FA-->>CC: observation + recordedFolderDispositions
    CC->>RP: prepare(input incl. store-held identities)
    RP-->>CC: change(replacement, deltas, relocations, identity changes, recents batch)
    CC->>RD: freshness: repeat locate + destination validation per relocation
    alt any relocation stale
        CC->>FA: refresh observation (existing refreshStaleObservation)
    else fresh
        CC->>RC: relocateKeys(batch); await flushApplicationAsync
        CC->>MC: applyRepositoryLifecycleChange + recordFolderIdentityChanges (revision-guarded)
        Note over MC: topology autosave may run from here on
        CC->>PE: deltas with relocatedWorktrees: root sync, Git, Forge, Bridge remount, terminal checks under P1
    end
```

## State, failure and concurrency

| Concern | Disposition |
|---|---|
| Scan order (S5) | Destination-first: entry identity → lookup → claim. Source-first: absent or replaced record → lookup → claim. Closure over holders makes a chain visible from either root. When nothing is admissible yet, the record is hidden, and the later lookup restores it. |
| Stale receipts | They are never evidence (S2) and remain inventory protection only. |
| Conflicts | Held destinations, cycles and swaps are declined, and Sep 11 R1 applies unchanged. No displaced-record state exists. |
| Staleness between evidence and apply | The freshness pass repeats lookup and destination validation (including both package reads), and the apply is revision-guarded. A stale result discards the change and refreshes through the existing retry limit (ScopedTopology.swift:12-27, 101). |
| Recents durability (S9) | Recents are durable **before** topology publication, so no topology save can precede them (closes N4 for autosave, RepositoryTopologyStore.swift:101-135). <br>• Crash after the recents flush, before topology durability: on restart the old core still holds the old keys. A simple move's destination key belongs to no record, so the startup sweep may delete it (loss), or replaying the move from an empty source leaves it intact. <br>• Chained entries are already cleared; clearing again is a no-op. <br>Old-key recents are never left for a new holder of P1 (a simple move emptied it). Replaying never permutes populated keys, because swaps are not admitted. |
| Local activity | Not moved. It is location-derived continuous coverage and restarts at P2. The existing root-sync revocation of changed keys applies (FilesystemActor+RepositoryLocalActivity.swift:20-32, 68-95). |
| Duplicate identity | No transfer (S3.4), plus a counter. Replacement validation adds the backstop `duplicateFolderIdentity` for store-held identities. |
| Terminal races | The report revision and session token gate apply. A newer report wins. Foreground handoff during a read → unsupported. Every correction ends at its correlated settled fact. |
| TCC or unreadable folders | `.undefined` or `.unavailable`, which means no proof. |

## Obligation realization

| Obligation | Owner and interface | State | Failure | Proof seam |
|---|---|---|---|---|
| S1 recording | discovery client enrollment → claims step 5 → store → `worktree` columns | store map plus persisted columns | undefined → none; malformed → none, rewritten | temp folders on the startup volume: `mv`, `cp -R`, `git clone`, `cp -c`, replacement during read; codec round trip; baseline resend on identity-only change |
| S2 evidence | `FilesystemActor` dispositions with closure | per-observation | receipts are not consulted | pure test: a held stale receipt at P1 neither blocks nor competes |
| S3 admission | dispositions, claim rounds, freshness pass | relocations | each condition declines independently | assignment matrix; two-read validation with a Git-directory retarget between reads; freshness failure → refresh |
| S4 effect | claims step 3; store; deltas | topology and identities | revision guard | real folders plus package and SQLite: UUID, pin, note, tags and recents across restart; no duplicate row |
| S5 order | both disposition sources plus closure | — | — | destination-first, source-first, a three-root chain in both orders, closed-app restore |
| S6 without proof | dispositions → none; declined claims | Sep 11 states | — | negative matrix including a held destination and a swap (R1 result equals today's) |
| S7 same-path | grouping loop, unchanged; consumption | — | — | P1 replaced while the original relocated: new row; unrepaired original: R1 as today |
| S8 no false merge | startup-volume binding; both-on-volume rule | — | other volumes undefined | Git directory on another volume (fixture) → undefined; clone and APFS clone → different |
| S9 recents | recency atom `relocateKeys` + flush before publication | live and durable | loss only | simple move; chain cleared; reused P1; restart between the recents flush and topology durability |
| S10 bound panes | App remount through `teardownView` + `createBridgePaneView` | pane content persisted | missing pane → skip | open file viewer, review pane, and visible and hidden Zoom companions: content from P2, old-generation request rejected, P1-replacement never read |
| S11 terminal truth | correction step plus reader | per-pane report revision and session token | unsupported → kept, checked at the next trigger | real child processes: foreground handoff, dead group leader, nested shell; runtime cases from the Specification proof table; correlated settled fact |
| S12 pane links | existing association after S11 | pane facets | — | App: a pane under P2 links to the same checkout ID; zmx session ID unchanged |
| S13 unwatch | Oct 7 design | — | — | Oct 7 proof |
| S14 (D2) | retention preparation: rows with no covering folder after removal | absence interval | — | controlled-clock collection (only if D2 is accepted) |
| S15 boundaries | all components above | — | — | source check: no MainActor I/O, no Git CLI, no writes into user folders, no process signals |
| S16 counters | performance trace recorder | bounded counts | — | marker-scoped verifier |

## Delivery shape

These are three independent PRs, each with its own proof:

1. **Remove Watched Folder** (Oct 7 design, plus S14 if D2 is accepted). Its design is already reviewed.
2. **Terminal location truth** (S11, S12 for unproved cases). It relinks the 22 legacy panes on launch, and does not depend on identity.
3. **Folder identity and relocation** (S1–S10, S15, S16). Bridge Lead review is required for the S10 remount.

Recorded identities exist only for checkouts validated after PR 3 ships. Moves made before then stay independent (D3).
