# Program design: repositories keep their identity when folders move

[Requirements](requirements.md) → [Specification](specification.md) (S1–S16) → this document. Grounded at `53eda46d7` (main `584f9992d` merged into `remove-watched-folder`). The agentstudio-git pin is `372fedb0`; no package change. **Status: proposed. It realizes owner decision D1 option A, which is not yet decided.**

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
- `ATTR_CMN_FILEID` is unique within its mounted volume, and `fsgetpath` resolves a number within one fsid (`man2/getattrlist.2:704-713`; `man2/fsgetpath.2:30-66`). Uniqueness therefore holds per *volume instance*, which is why E3 binds the proof to the mounted startup volume. Images and snapshots are other instances.
- A host probe found the startup volume qualifying (persistent, PATH_FROM_ID and 64-bit IDs set; directory hard links not set). It also found `~/code`, `~/Documents` and `/private/tmp` on one device.
- Measured on that volume:
  - `mv` kept the numbers of both the checkout folder and `.git`;
  - `cp -R`, `git clone` and `cp -c` produced new numbers;
  - `fsgetpath` returned the new path after a move, and `ENOENT` after deletion, unprivileged.

**2. Ask, don't infer.** A lookup is the only location evidence (S2). Two kinds of cached state are not evidence, because both can be stale:

- receipts from other roots (`otherObservedEntries`, FilesystemActor+WatchedFolderResultApplication.swift:159-174);
- earlier scans.

The startup volume says where a folder is now. That makes assignment order-independent without a mailbox or provisional IDs.

**3. Same UUID, new path.** Today a different-path reassociation issues a new checkout UUID (`WorkspaceCacheCoordinatorRepoMoveTests.swift:91-154`). These consumers already handle a path change:

- the lifetime index advances on (ID, path) (RepositoryObservationLifetime.swift:42-66);
- root sync re-registers (WorkspaceSurfaceCoordinator+FilesystemSource.swift:560-584);
- the Git projector compares contexts (GitWorkingDirectoryProjector.swift:413-448, 535-586).

These consumers capture the old location, and need an explicit relocation edge:

- the live recency owner (EntityRecencyAtoms.swift:7-40; EntityRecencyStore.swift:89-94, 177-185);
- the activity owner (RepositoryLocalActivityStore.swift:35-90);
- Bridge pane authority (`BridgePaneState.source = .workspace(rootPath:)`, BridgePaneState.swift:48; captured once at BridgePaneController+Bootstrap.swift:757-778);
- Zoom companion reuse (WorkspaceSurfaceCoordinator+ZoomCompanion.swift:180-200).

**4. Panes cannot follow by identity alone.** The Ghostty zsh integration reports `$PWD` at every prompt (`vendor/ghostty/src/shell-integration/zsh/ghostty-integration:235-241`), and after a move that path is stale. Ghostty drops OSC 7 from a non-local host (`vendor/ghostty/src/termio/stream_handler.zig:1518-1523`). The true location belongs to the terminal's foreground process. Its group is `e_tpgid` of the session's terminal leader (`sys/proc_info.h:78`). The leader's incarnation comes from the existing `ZmxSessionControlling.observeSessionIdentity` (ZmxSessionIdentity.swift:3-17).

## Components

No new atom, store, table or coordinator is added, and there is no package change. The persisted format gains three nullable columns on `worktree`. One runtime fact is added: the terminal correction outcome. Both need owner acknowledgement with D1.

| Component | Slice | Owns | Change |
|---|---|---|---|
| `StartupVolumeFolderIdentityReader` (new) | Infrastructure/FolderIdentity | Darwin facts only | It decides whether the startup volume qualifies: the fsid and UUID of the volume holding the home folder, plus its capability bits. It reads `identity(of:)`: a path's fsid must equal the startup fsid, and the read returns the folder number. It answers `locate(number)` with `fsgetpath` on the startup fsid. Outcomes: `.identified` / `.undefined(reason)`; `.located(URL)` / `.notFound` / `.unavailable`. No Git. |
| `RepoScannerGitDiscoveryClient` | Infrastructure | Package validation into scanner evidence | **Enrollment:** it reads the candidate path's identity before the package read. After the read it reads the identity of `canonicalWorktreePath` and `canonicalGitDirectory`. The two checkout-folder numbers must be equal, both folders must be on the startup volume, and the result attaches as `ResolvedGitEntry.folderIdentity`; otherwise nil. A replacement during the read yields nil (no proof), not absence. **Destination validation** (S3.3), `validateRelocationDestination(path, expected: I)`, runs in this order: identity(path) == I.checkout; package read; canonical worktree == path and role matches; identity(gitDirectory) == I.gitDirectory; identity(path) == I.checkout again. Any mismatch declines. The adapter currently discards the Git directory (:51-91). |
| `CheckoutFolderIdentity` (new value) | Core/Models | `volumeUUID`, `checkoutFolderNumber`, `gitDirectoryNumber` | Value type with Equatable and Hashable conformance. |
| Recorded identities | Core/State/MainActor/Persistence: `RepositoryTopologyStore` | The persisted evidence, which has no observer | The store holds `recordedFolderIdentitiesByWorktreeID` as non-observable state, loaded with the topology. `recordFolderIdentityChanges(_:revision:)` runs in the same MainActor step as `applyRepositoryLifecycleChange` (precedent: `recordReparenting`, :28-31). The store persists them with its next topology save, and `captureRepositoryLifecycleInput` reads them. **No atom field** (atom rule; F8). |
| Core persistence | Core persistence | `worktree` rows | Additive migration `ALTER TABLE worktree ADD COLUMN`: `folder_volume_uuid TEXT`, `folder_checkout_number INTEGER`, `folder_git_directory_number INTEGER`. The UInt64 values are bit-cast. All three present decodes to an identity; all absent to none; any other combination decodes to none, logs a diagnostic, and is rewritten at the next validation. No CHECK and no trigger. The existing UNIQUE staging keeps swaps valid (WorkspaceCoreRepository+TopologyMutation.swift:173-215). |
| Scan baseline | Core/RuntimeEventSystem/Filesystem | `WatchedFolderScanBaseline` | Carries the recorded identity per checkout. The coordinator resends the baseline when either the membership generation or an identity-change generation advances. Today it resends only on membership change (ScopedTopology.swift:84-89). |
| Folder dispositions | `FilesystemActor`, observation assembly (FilesystemActor+WatchedFolderResultApplication.swift:176-192) | Evidence, not decisions | Each observation gains `recordedFolderDispositions` (detailed below). The I/O runs in `@concurrent nonisolated` helpers, never on the actor executor. |
| Identity claims | `RepositoryLifecycleReconciliation.prepare` (off-main) | Identity resolution (July TA2) | A claims phase runs before the grouping loop (detailed below). `RepositoryLifecycleChange` gains `relocations`, `identityChanges` and `localStateRelocationBatch`. |
| Relocation effects | `WorkspaceCacheCoordinator+ScopedTopology` (App) | Ordering | Freshness check, apply, local-state batch, durable order, then runtime effects. See the flow below. |
| Recency relocation | `ApplicationEntityRecencyAtom.relocateKeys(_ batch)` | Live recency | An assignment-only key replacement. `EntityRecencyStore` then persists the snapshot it already owns. |
| Activity relocation | `RepositoryLocalActivityStore.relocateKeys(_ batch)` | Live activity and its authority | It revokes authority for every old and new key (`revokeCurrentSessionAuthority`, :69-95), so an in-flight old-key commit cannot regain authority. It moves the captured rows in one datastore transaction, then publishes the moved values as authoritative. |
| `WorktreeTopologyDelta` | Core | The topology effect contract | Adds `relocatedWorktrees: [RelocatedWorktreeEntry(id, previousPath, path)]`. |
| Bound-pane rebinding | `WorkspaceSurfaceCoordinator` (App), with the Bridge pane controller | E8 binding | For each relocated worktree, every Bridge pane whose runtime `worktreeId` matches and whose `.workspace(rootPath:)` equals P1 gets its stored root updated to P2 through the existing pane content mutation, which is persisted. The pane controller then reinstalls its product session through the existing teardown and bootstrap, so its authority binds P2. Subscriptions holding the old token are rejected (BridgeWorktreeFileSourceProvider.swift:39). A Zoom companion for that worktree is rebound the same way and keeps its source-pane relationship. Bridge Lead review is required. |
| `TerminalTrueLocationReader` (new) | Infrastructure | Reading a process's directory | Input is the zmx session identity: boot ID plus leader incarnation. It checks that the boot ID equals the current boot and that the leader's incarnation matches. It reads the leader's `e_tpgid` → foreground leader F. It confirms F is the leader's descendant through a bounded ppid walk (limit in `AppPolicies`), then reads F's `pvi_cdir`. It re-reads F's and the leader's incarnations, which must be equal. Outcomes: `.located(URL)` / `.unsupported(reason)`. It is read-only and never calls retirement or kill capabilities. |
| Terminal location correction (new) | Features/Terminal runtime | The S11 decision | State per pane: raw report, report revision, effective location, and session token (session ID and surface). A trigger reads off-main; a result is applied on MainActor only if the report revision and session token are unchanged. The effective location is published through the TerminalRuntime CWD route (TerminalRuntime.swift:276-280), followed by the existing association. If unsupported, the raw report is marked failed (`recordFailedCWDPublication`, GhosttyActionRouter+LocalActions.swift:556-561), so the accumulator readmits the same report (TerminalLocalActionAccumulator.swift:563-567). There is no timer. Each correction posts the outcome fact `terminalLocationCorrectionSettled(paneId, outcome)` (new runtime fact; owner acknowledgement). |

## Folder dispositions: how the observation is assembled (S2)

The `FilesystemActor` builds the set of looked-up records. The set has two parts:

1. records whose recorded identity equals the identity of an entry at another path in this observation;
2. records under root R whose recorded location is absent from the inventory, or presents another identity.

For each record in the set, the actor locates its folder and attaches one disposition:

- `.relocatable(entry at P2)`: located at P2 ≠ P1, P2 is inside a current watched root (existing containment: FilesystemPathCanonicalizer.swift:233-247; FilesystemRootOwnership.swift:149-169), and `validateRelocationDestination` admits it;
- `.existsElsewhere`: located, but outside watched roots, or not admitted by Git yet;
- `.notFound`;
- `.unavailable`.

Cached receipts never become dispositions.

## Identity claims in `prepare`

1. **Candidate claims.** One per `.relocatable` disposition. Drop a claim when another record holds the same identity (S3.4), or when the role disagrees.
2. **Held destinations.** A claim survives if P2 is held by no record, or only by a record that itself has a surviving claim away from P2 (S3.5). Iterate to a fixed point, so swaps and cycles survive and a chain blocked anywhere is declined.
3. **Apply surviving claims simultaneously.** For each claimed record C:
   - update its path and name, plus its family's `repoPath` when C is main;
   - clear the absences of C and its family;
   - re-derive the stable keys of C and its family from P2;
   - record the relocation and the key pair for the local batch.

   The claimed records and their destination paths are consumed.
4. **Grouping loop** (RepositoryLifecycleReconciliation.swift:65-110) over the remaining entries. It skips consumed records and paths. Same-path reuse of a record C for an entry whose identity differs from C's recorded identity follows S7:
   - reuse when C has no recorded identity, or C's disposition is `.notFound`;
   - otherwise issue a new UUID for the entry and keep C hidden with its identity.
5. **Identity changes.** Each matched entry refreshes its record's identity. If a refreshed identity is held by another record, that record loses it (one identity, one record).

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
    participant MC as MainActor apply (atom + store)
    participant LS as Recency atom/store + activity store
    participant PE as Pane effects (Bridge rebind, terminal correction)
    FA->>RD: scan entries (enrollment identity)
    FA->>RD: locate recorded folders; validate admissible destinations
    FA-->>CC: observation + recordedFolderDispositions
    CC->>RP: prepare(input incl. store-held identities)
    RP-->>CC: change(replacement, deltas, relocations, identity changes, key batch)
    CC->>RD: freshness: locate each relocated folder again (S3.6)
    alt any relocation stale
        CC->>FA: refresh observation (existing refreshStaleObservation)
    else fresh
        CC->>MC: applyRepositoryLifecycleChange + recordFolderIdentityChanges (revision-guarded)
        CC->>LS: relocateKeys(batch), then await local durability
        CC->>MC: topology flushAsync (core durable)
        CC->>PE: deltas with relocatedWorktrees: root sync, Git, Forge, Bridge rebind, terminal checks under P1
    end
```

## State, failure and concurrency

| Concern | Disposition |
|---|---|
| Scan order (S5) | Destination-first: entry identity → lookup → claim. Source-first: absent or replaced record → lookup → claim. Both converge. When neither applies yet, the record is hidden, and the later lookup restores it. |
| Stale receipts | They are never evidence (S2) and remain inventory protection only (existing). |
| Occupied destination | Declined unless the holder moves away in the same claims fixed point. Sep 11 R1 then applies to the holder (S6 limit). |
| Replacement before repair | S7 blocks reuse while the original folder is `.existsElsewhere`. The original keeps its identity and relocates after repair. |
| Staleness between evidence and apply | A freshness lookup runs just before apply, and the apply is revision-guarded. A stale result discards the change and refreshes through the existing retry limit (ScopedTopology.swift:12-27, 101). |
| Durability order | Local re-key is made durable **before** the core flush. Today the core flush runs after effects (ScopedTopology.swift:71-95). This change moves only the relocation's local batch ahead of it. Crash outcomes by stage: <br>• before local durability: old core plus old local state, so the next reconciliation repeats the relocation; <br>• after local durability, before the core flush: on restart the relocation is repeated. Moving an empty source leaves the destination untouched, so a sweep that runs earlier can delete the moved rows. That is loss, not misattribution; <br>• after both: done. <br>Old-key rows are never left for a new occupant of P1 (S9). |
| Activity in flight | Revoking authority for both keys means a commit captured for the old key cannot publish after the move (RepositoryLocalActivityStore.swift:36-60). |
| Duplicate identity | No transfer for anyone (S3.4), plus a counter. Replacement validation adds the backstop `duplicateFolderIdentity` for store-held identities. |
| Terminal races | The report revision and session token gate apply. A newer report wins. Unsupported results readmit the same report. Every correction ends at its settled fact. |
| TCC or unreadable folders | The read returns `.undefined` or `.unavailable`, which means no claim and no reuse (S7 fails closed). |

## Obligation realization

| Obligation | Owner and interface | State | Failure | Proof seam |
|---|---|---|---|---|
| S1 recording | discovery client enrollment → claims step 5 → store `recordFolderIdentityChanges` → `worktree` columns | store map plus persisted columns | undefined → none; malformed → none, rewritten | real-volume temp folders: `mv`, `cp -R`, `git clone`, `cp -c`, replacement during read; codec round trip; baseline resend on identity-only change |
| S2 evidence | `FilesystemActor` dispositions | per-observation | cached receipts are not consulted | pure test: a held stale receipt at P1 does not block or compete |
| S3 admission | dispositions, claims 1–2, freshness check | relocations in the change | each condition declines independently | assignment matrix; destination validation seams at each read; freshness failure → refresh |
| S4 effect | claims step 3; store; deltas | topology and identities | revision guard | integration on real folders plus package and SQLite: UUID, pin, note, tags across restart; no duplicate row |
| S5 order | both disposition sources | — | — | destination-first, source-first, closed-app restore |
| S6 without proof | dispositions → none; claims declined | Sep 11 states | — | negative matrix including held destination |
| S7 same-path | claims step 4 | identity kept on hidden C | `.unavailable` fails closed | P1 replaced while the original sits unrepaired at P2, then repaired |
| S8 no false merge | E3 instance binding, E4 both-on-volume rule | — | other volumes undefined | Git directory on another volume (fixture) → undefined; clone and APFS clone → different |
| S9 local state | recency atom and store, activity store, durability order | live and durable | loss only, never misattribution | delayed full recency save; held activity commit; A↔B; reused P1; restart at each stage |
| S10 bound panes | coordinator rebinding plus Bridge session reinstall | pane content persisted | missing pane → skip | open file viewer, review pane, and visible and hidden Zoom companions; old generation rejected; P1-replacement never read |
| S11 terminal truth | correction step plus reader | per-pane raw and effective | unsupported → readmit report | real child-process reader; runtime cases from the Specification proof table; correlated settled fact |
| S12 pane links | existing association after S11 | pane facets | — | App: pane under P2 links to the same checkout ID; zmx session ID unchanged |
| S13 unwatch | Oct 7 design | — | — | Oct 7 proof |
| S14 (D2) | retention preparation: rows with no covering folder after removal | absence interval | — | controlled-clock collection (only if D2 is accepted) |
| S15 boundaries | all components above | — | — | source check: no MainActor I/O, no Git CLI, no writes into user folders, no process signals |
| S16 counters | performance trace recorder | bounded counts | — | marker-scoped verifier |

## Delivery shape

These are three independent PRs, each with its own proof:

1. **Remove Watched Folder** (Oct 7 design, plus S14 if D2 is accepted). Its design is already reviewed.
2. **Terminal location truth** (S11, S12 for unproved cases). It relinks the 22 legacy panes on launch, and does not depend on identity.
3. **Folder identity and relocation** (S1–S10, S15, S16). Bridge Lead review is required for the S10 rebinding.

Recorded identities exist only for checkouts validated after PR 3 ships. Moves made before then stay independent (D3).
