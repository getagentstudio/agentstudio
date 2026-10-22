# Core schema key and constraint evidence

source: All 28 final catalog-selected core tables declare a PK: 16 single TEXT, one INTEGER and 11 composite TEXT keys. There are 42 surviving attached triggers on 16 tables, 33 FKs, 16 non-PK unique constraints/indexes and 23 SQL CHECKs. No scoped table declares virtual-table, AUTOINCREMENT, STRICT or WITHOUT ROWID forms. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:18).

inference: All 28 meet the proposed declared-PK prerequisite; selecting the 16 trigger-bearing tables as-is conflicts with the bounded SO6 no-trigger profile. This is a source cross-check, not target-schema design, engine adoption or runtime admission. [profile](shared-schema-profile.txt).

source: Product source HEAD: 624300332f5e50f7bb8cbb9fc786d5e5b4a3d462. Catalog unchanged. Parent-captured SO5-SO7 excerpt read and SHA-256 checked here: a1341987af7794258c619c52056b1d4f8d02128449946a12c56cc28787e5bb82. Sibling specification is concurrently edited. [source](../../../designs/02-data-ownership-replication/research/data-catalog.json:1).

## Exact final inventory

source: SQL PK column order/types, explicit NOT NULL, attached-trigger counts and constraint counts are below. Full FK columns/targets/actions, unique clauses, CHECKs, trigger names/events/bodies and migration derivation are in the JSON. NN means every PK column explicitly declares NOT NULL; it is not inferred from PRIMARY KEY. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).

| Basis | Table | Ordered PK columns and SQL types | All PK explicit NN | Triggers | FKs | Unique excluding PK | CHECKs | Decisive CREATE |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| source | workspace | id TEXT | no | 0 | 0 | 0 | 0 | [WorkspaceCoreMigrations.swift:128](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:128) |
| source | app_workspace_selection | singleton_id INTEGER | no | 0 | 1 | 0 | 1 | [WorkspaceCoreMigrations.swift:136](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:136) |
| source | watched_path | id TEXT | no | 0 | 0 | 1 | 0 | [WorkspaceCoreMigrations+GlobalTopology.swift:9](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:9) |
| source | repo | id TEXT | no | 0 | 0 | 1 | 1 | [WorkspaceCoreMigrations+GlobalTopology.swift:17](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:17) |
| source | worktree | id TEXT | no | 0 | 1 | 1 | 1 | [WorkspaceCoreMigrations+GlobalTopology.swift:29](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:29) |
| source | repo_tag | repo_id TEXT, tag TEXT | yes | 0 | 1 | 0 | 1 | [WorkspaceCoreMigrations+GlobalTopology.swift:42](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:42) |
| source | unavailable_repo | repo_id TEXT | no | 0 | 1 | 0 | 1 | [WorkspaceCoreMigrations+RepositoryAbsence.swift:20](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+RepositoryAbsence.swift:20) |
| source | unavailable_worktree | worktree_id TEXT | no | 0 | 1 | 0 | 1 | [WorkspaceCoreMigrations+RepositoryAbsence.swift:20](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+RepositoryAbsence.swift:20) |
| source | pane | id TEXT | no | 4 | 2 | 0 | 3 | [WorkspaceCoreMigrations.swift:256](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:256) |
| source | pane_content_terminal | pane_id TEXT | no | 4 | 2 | 0 | 0 | [WorkspaceCoreMigrations+SessionOwnership.swift:24](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:24) |
| source | pane_content_webview | pane_id TEXT | no | 2 | 1 | 0 | 0 | [WorkspaceCoreMigrations.swift:377](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:377) |
| source | pane_content_code_viewer | pane_id TEXT | no | 2 | 1 | 0 | 0 | [WorkspaceCoreMigrations.swift:385](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:385) |
| source | pane_content_payload | pane_id TEXT | no | 2 | 1 | 0 | 0 | [WorkspaceCoreMigrations.swift:392](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:392) |
| source | drawer | id TEXT | no | 0 | 1 | 1 | 0 | [WorkspaceCoreMigrations.swift:399](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:399) |
| source | drawer_pane | drawer_id TEXT, pane_id TEXT | yes | 2 | 2 | 2 | 0 | [WorkspaceCoreMigrations.swift:406](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:406) |
| source | tab_shell | id TEXT | no | 0 | 1 | 1 | 1 | [WorkspaceCoreMigrations.swift:520](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:520) |
| source | tab_pane | tab_id TEXT, pane_id TEXT | yes | 2 | 2 | 2 | 0 | [WorkspaceCoreMigrations.swift:529](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:529) |
| source | tab_arrangement | id TEXT | no | 0 | 1 | 2 | 1 | [WorkspaceCoreMigrations.swift:557](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:557) |
| source | arrangement_layout_pane | arrangement_id TEXT, pane_id TEXT | yes | 3 | 2 | 1 | 0 | [WorkspaceCoreMigrations.swift:573](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:573) |
| source | arrangement_layout_divider | arrangement_id TEXT, divider_id TEXT | yes | 0 | 1 | 1 | 0 | [WorkspaceCoreMigrations.swift:609](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:609) |
| source | arrangement_minimized_pane | arrangement_id TEXT, pane_id TEXT | yes | 2 | 2 | 0 | 0 | [WorkspaceCoreMigrations.swift:632](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:632) |
| source | arrangement_drawer_view | arrangement_id TEXT, drawer_id TEXT | yes | 2 | 2 | 0 | 0 | [WorkspaceCoreMigrations.swift:665](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:665) |
| source | drawer_view_layout_pane | arrangement_id TEXT, drawer_id TEXT, pane_id TEXT | yes | 5 | 2 | 1 | 0 | [WorkspaceCoreMigrations.swift:709](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:709) |
| source | drawer_view_layout_divider | arrangement_id TEXT, drawer_id TEXT, row_kind TEXT, divider_id TEXT | yes | 2 | 1 | 1 | 0 | [WorkspaceCoreMigrations.swift:750](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:750) |
| source | drawer_view_minimized_pane | arrangement_id TEXT, drawer_id TEXT, pane_id TEXT | yes | 2 | 2 | 0 | 0 | [WorkspaceCoreMigrations.swift:782](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:782) |
| source | workspace_terminal_session_ownership | session_id TEXT | yes | 3 | 0 | 0 | 4 | [WorkspaceCoreMigrations+SessionOwnership.swift:4](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:4) |
| source | workspace_undo_close | close_id TEXT | yes | 2 | 0 | 1 | 8 | [WorkspaceCoreMigrations+SessionOwnership.swift:85](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:85) |
| source | workspace_undo_close_member | close_id TEXT, pane_id TEXT | yes | 3 | 2 | 0 | 0 | [WorkspaceCoreMigrations+SessionOwnership.swift:109](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:109) |

## Decisive exceptions

source: drawer_view_layout_pane PK (arrangement_id, drawer_id, pane_id) excludes row_kind; drawer_view_layout_divider PK (arrangement_id, drawer_id, row_kind, divider_id) includes it. Both row-kind domains use guards added in 005, rather than SQL CHECKs. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:709). [divider DDL](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:750); [row-kind guards](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+TabGraphLayoutRepair.swift:84).

source: tab_arrangement retains a partial unique index on tab_id WHERE is_default = 1, plus tab_id/sort_index uniqueness. The shows_minimized_panes column and its CHECK retire in 014. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:568). [drop](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:60).

source: pane_content_terminal is rebuilt in the ownership migration: pane_id TEXT PRIMARY KEY; nullable zmx_session_id TEXT FK to ownership(session_id) ON DELETE RESTRICT; two content-type and two ownership triggers. SQL declares no UUIDv7 format. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:24).

source: Final pane facets are paired nullable TEXT with no FKs: original facets/guards removed in 015 and new columns added in 016. Undo workspace_id and member pane_id likewise have no FKs; member session FK is RESTRICT. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+PaneAssociation.swift:2). [facet removal](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+PaneTopologyFacets.swift:2); [Undo DDL](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:86).

source: arrangement_layout_divider has no attached trigger but is mutated by the pruning trigger attached to arrangement_layout_pane. Drawer divider pruning is attached to drawer_view_layout_pane. Ownership insertion is attached to pane_content_terminal. JSON separates these indirect writes. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+TabGraphLayoutRepair.swift:49). [drawer prune](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+TabGraphLayoutRepair.swift:66); [ownership insert](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+SessionOwnership.swift:57).

source: 013 replaces workspace-scoped topology with five global definitions. 018 rebuilds unavailable_repo and creates unavailable_worktree with the timing-CHECK helper. Retired status/import tables, transition names, GRDB bookkeeping and engine internals are outside the 28 final rows. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:2). [018 helper calls](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+RepositoryAbsence.swift:4).

## Key nullability and rowid syntax

source: Thirteen tables explicitly mark all PK columns NOT NULL: all 11 composite-PK tables plus workspace_terminal_session_ownership and workspace_undo_close. Fourteen single TEXT PKs omit NOT NULL: workspace, watched_path, repo, worktree, unavailable_repo, unavailable_worktree, pane, pane_content_terminal, pane_content_webview, pane_content_code_viewer, pane_content_payload, drawer, tab_shell, tab_arrangement. Per-row flags and exact anchors are in JSON. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).

source: app_workspace_selection.singleton_id is exactly INTEGER PRIMARY KEY CHECK(singleton_id = 1), without DESC or AUTOINCREMENT. No scoped CREATE has STRICT or WITHOUT ROWID. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:136).

inference: Under documented SQLite syntax, this INTEGER key is a rowid alias; ordinary rowid TEXT PRIMARY KEY declarations without explicit NOT NULL do not alone enforce key non-nullness. STRICT/WITHOUT ROWID would affect these rules but are absent. No claim that NULL key rows exist or that Turso behaves identically. Read parent-captured [CREATE TABLE sections 3.5 and 5](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/sqlite-create-table.txt:1), [WITHOUT ROWID section 2](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/sqlite-without-rowid.txt:1), [STRICT section 2](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/sqlite-strict-tables.txt:1).

## Source walk and limits

source: Full base and all 11 WorkspaceCoreMigrations+ files read; 19 registration entries followed in array order, retaining both distinct 017 identifiers. Pre009Backup is a detector, not another creator. Interpolated content types and top/bottom literals verified in owning definitions. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations.swift:18). [content literals](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/SQLitePaneContentTypeStorage.swift:3); [row literals](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/SQLiteTabGraphStorage.swift:4).

source: The repository migrate method and existing-core startup preparer reference this same migrator; these are source wiring observations only. [source](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreRepository.swift:41). [startup](../../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:688).

source: Static report validation matched 28 exact unique catalog names, required fields and 108 readable in-range source anchors. A text-only reconstruction followed CREATE/DROP/ALTER/rebuild/rename plus trigger/index changes. No SQLite, probes, tests, builds or runtime execution. Coverage/count checks are not constraint-behavior proof. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).

source: Source classes: current local code/docs; named sibling bounded profile; parent-provided official SQLite captures. Memory search adopted no current evidence. External OSS/network, sessions, Reader and UI/runtime observation were unnecessary or excluded. Worker spawned no helpers; parent owns independent verification. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).

### Verbatim discovery queries

- `rg -n 'daemon|schema|core.sqlite' /Users/shravansunder/.codex/memories/MEMORY.md`
- `rg -n 'CREATE|ALTER|DROP|registerMigration|apply|migrat' Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations*.swift`
- `rg -n 'SE18|SO6|SO7|primary key|PRIMARY KEY|trigger|virtual' /Users/shravansunder/code/projects/codex-router.collab-improvements/docs/specs/2026-10-16-agent-fleet-sync/2026-10-16-agent-fleet-sync.md`
- `rg -n 'enum SQLitePaneContentTypeStorage|static let (terminal|browser|diff|editor|review|agent|codeViewer|pluginPrefix|topRow|bottomRow)' Sources/AgentStudio/Core/State`
- `rg --files Sources | rg 'WorkspaceSQLiteDatastore|WorkspaceSQLiteDatastoreFactory'`
- `rg -n 'WorkspaceCoreMigrations' Sources Tools --glob '*.swift'`
- `rg -n 'CREATE VIRTUAL TABLE|AUTOINCREMENT|WITHOUT ROWID|\bSTRICT\b' Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations*.swift`
- `rg -n 'CREATE TRIGGER|DROP TRIGGER|CREATE VIRTUAL TABLE|ALTER TABLE (workspace|app_workspace_selection|watched_path|repo|worktree|repo_tag|unavailable_repo|unavailable_worktree|pane|pane_content_terminal|pane_content_webview|pane_content_code_viewer|pane_content_payload|drawer|drawer_pane|tab_shell|tab_pane|tab_arrangement|arrangement_layout_pane|arrangement_layout_divider|arrangement_minimized_pane|arrangement_drawer_view|drawer_view_layout_pane|drawer_view_layout_divider|drawer_view_minimized_pane|workspace_terminal_session_ownership|workspace_undo_close|workspace_undo_close_member)\b' Sources Tools --glob '*.swift' --glob '*.sql' --glob '!WorkspaceCoreMigrations*'`

source: No CREATE VIRTUAL TABLE/AUTOINCREMENT/WITHOUT ROWID/STRICT matches in complete migration family (exit 1). [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).
source: Outside-family scoped ALTER/trigger query returned only unrelated search_document_fts virtual-table declaration; no scoped match. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).
source: Guessed WorkspaceSQLiteDatastore.swift path missing; rg --files identified WorkspaceSQLiteDatastoreActor.swift, whose startup migrator reference at line 691 was read. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).
source: Memory registry search returned unrelated historical leads; none adopted for current conclusions. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).
source: Prior evidence report was discovery only; current migration DDL and constants were decisive. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).

### Unresolved beyond source scope

gaps: Actual applied schema, integrity and engine admission unobserved. Searched: Registered source migrations only; execution/probes forbidden. Settled by: Separately authorized isolated migration/schema/engine proof.
gaps: Replicated subset and replacements for trigger obligations unselected. Searched: Bounded shared SO5-SO7 excerpt and current DDL. Settled by: Lead/owner target-schema and selection design; no adoption decision here.

source: No unresolved per-table declaration row remains. Only the two commissioned reports were written; catalog and product source unchanged. [source](../../../../../../tmp/practices-research/2026-10-16-daemon-schema-admission/core-key-evidence.json:1).
