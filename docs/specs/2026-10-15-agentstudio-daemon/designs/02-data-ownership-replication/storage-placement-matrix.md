# Every current table: proposed placement

**Read the [storage design](storage-placement-design.md) first.** This is the exhaustive placement view over the existing [86-table / 597-column source catalog](research/data-catalog.json). Current declarations, writers and key evidence remain source facts; the placement entries below are a Lead proposal. No row declares a target table eligible for replication.

Each current column has a placement entry in the catalog. A default applies only where no field override is listed. “Split” and “pending” are explicit unresolved allocations, not a disguised final home. Historical placement proposals remain separately retained; they cannot reopen the selected shared layout/read state or Mac+iOS Gateway outcome.

## How to read the transaction references

The three bounded source packets are [Sessions/context](../../research/evidence/2026-10-18-daemon-storage-units/context-transactions.md), [workspace/annotation](../../research/evidence/2026-10-18-daemon-storage-units/workspace-annotation-transactions.md) and [repository/native](../../research/evidence/2026-10-18-daemon-storage-units/repository-native-transactions.md). `WA-G1` means group G1 in the workspace/annotation packet; `RN01` means the repository packet. `CX-G1` means group G1 in the Sessions/context packet. A group is an inspected operation family, not an assertion that every listed table always changes together. The [normalized group-table index](../../research/evidence/2026-10-18-daemon-storage-units/normalized-group-table-index.json) retains read/write/prior-read/external-file-read lists from every packet variant and union; earlier or external reads are not cross-file atomic predicates.

## Complete table map

The seven branches below link to their detailed tables. Counts describe existing logical tables, not future database files.

- [Host-owned state: 41 tables](#host-owned-state)
- [Shared workspace state: 13 tables](#shared-workspace-state)
- [Rows still needing a split or scope decision: 18 tables](#rows-still-needing-a-split-or-scope-decision)
- [Native UX-client state: 4 tables](#native-ux-client-state)
- [Other private boundaries: 5 tables](#other-private-boundaries)
- [Gateway derived state: 2 tables](#gateway-derived-state)
- [Retained dormant features: 3 tables](#retained-dormant-features)

Copy labels below have one meaning each:

| Copy label | Meaning |
| --- | --- |
| Candidate | Requires target schema, exact field audience and a whole-unit grant. No export is declared. |
| Private | Not selected for whole-copy export; remains at its actual private owner. |
| Local | Native/derived state; not a faithful source copy. |
| Hold | Resolve the named semantic/field allocation before any whole-table export. |

### Host-owned state

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `core.sqlite` / `watched_path` | 4 | Addressed Host topology/observation | RN01 | Candidate |
| `core.sqlite` / `repo` | 7 | Addressed Host topology/observation | RN01, RN03 | Candidate |
| `core.sqlite` / `worktree` | 7 | Addressed Host topology/observation | RN01, RN03, WA-G1 | Candidate |
| `core.sqlite` / `repo_tag` | 2 | Addressed Host topology/observation | RN01 | Candidate |
| `core.sqlite` / `unavailable_repo` | 6 | Addressed Host topology/observation | RN01, WA-G1 | Candidate |
| `core.sqlite` / `unavailable_worktree` | 6 | Addressed Host topology/observation | RN01, WA-G1 | Candidate |
| `local.sqlite` / `sessions_conversation` | 5 | Addressed Host session/context | CX-G1 | Candidate |
| `local.sqlite` / `sessions_operation` | 12 | Private Host admission/checkpoint state | CX-G1 | Private |
| `local.sqlite` / `sessions_pane_binding` | 12 | Addressed Host session/context | CX-G1, CX-G2, CX-G3, CX-G4 | Candidate |
| `local.sqlite` / `sessions_source` | 13 | Addressed Host session/context | CX-G1 | Candidate |
| `local.sqlite` / `sessions_evidence` | 21 | Addressed Host session/context | CX-G1 | Candidate |
| `local.sqlite` / `sessions_provider_question` | 5 | Addressed Host session/context | CX-G1 | Candidate |
| `local.sqlite` / `sessions_provider_question_option` | 5 | Addressed Host session/context | CX-G1 | Candidate |
| `local.sqlite` / `pane_state` | 21 | Addressed Host session/context | CX-G2, CX-G3, CX-G4, CX-G5, WA-G4 | Candidate |
| `local.sqlite` / `pane_state_action` | 10 | Addressed Host session/context | CX-G2, CX-G5 | Candidate |
| `local.sqlite` / `pane_request` | 31 | Addressed Host session/context | CX-G3, CX-G4, CX-G5, WA-G4 | Candidate |
| `local.sqlite` / `pane_event` | 20 | Addressed Host session/context | CX-G3, CX-G4, CX-G5, WA-G4 | Candidate |
| `local.sqlite` / `pane_request_action` | 10 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_event_action` | 10 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_request_choice` | 4 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_request_property` | 12 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_request_required` | 3 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_request_property_choice` | 4 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_request_answer_value` | 6 | Addressed Host session/context | CX-G3, CX-G4, CX-G5 | Candidate |
| `local.sqlite` / `pane_write_order` | 5 | Private Host admission/checkpoint state | CX-G2, CX-G5, WA-G4 | Private |
| `local.sqlite` / `pane_epoch_claim` | 6 | Private Host admission/checkpoint state | CX-G2, CX-G5, WA-G4 | Private |
| `local.sqlite` / `pane_answer_position` | 4 | Private Host admission/checkpoint state | CX-G3, CX-G4, CX-G5, WA-G4 | Private |
| `local.sqlite` / `pane_retirement` | 3 | Addressed Host session/context | CX-G2, CX-G3, CX-G4, CX-G5, WA-G4 | Candidate |
| `local.sqlite` / `pane_context_cli_outbox_cursor` | 2 | Private Host admission/checkpoint state | CX-G3 | Private |
| `local.sqlite` / `cache_metadata` | 3 | Host-origin observations; Gateway prepares separate views | RN03 | Candidate |
| `local.sqlite` / `cache_repo_enrichment` | 10 | Host-origin observations; Gateway prepares separate views | RN03 | Candidate |
| `local.sqlite` / `cache_worktree_enrichment` | 6 | Host-origin observations; Gateway prepares separate views | RN03 | Candidate |
| `local.sqlite` / `local_repository_activity` | 7 | Addressed Host activity plus private source checkpoint | RN01, RN02, RN03 | Candidate |
| `local.sqlite` / `local_repository_activity_cursor` | 3 | Private Host admission/checkpoint state | RN02 | Private |
| `local.sqlite` / `annotation_session` | 11 | Addressed Host annotation workflow | WA-G5, WA-G6, WA-G7 | Candidate |
| `local.sqlite` / `annotation_thread` | 10 | Addressed Host annotation workflow | WA-G5, WA-G6 | Candidate |
| `local.sqlite` / `annotation_message` | 13 | Addressed Host annotation workflow | WA-G5, WA-G6, WA-G7 | Candidate |
| `local.sqlite` / `annotation_message_draft` | 6 | Addressed Host annotation workflow | WA-G5, WA-G6 | Candidate |
| `local.sqlite` / `annotation_output_attempt` | 14 | Addressed Host annotation workflow | WA-G5, WA-G6, WA-G7 | Candidate |
| `local.sqlite` / `annotation_output_attempt_message` | 4 | Addressed Host annotation workflow | WA-G5, WA-G6, WA-G7 | Candidate |
| `local.sqlite` / `annotation_output_event` | 4 | Addressed Host annotation workflow | WA-G6, WA-G7 | Candidate |

### Shared workspace state

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `core.sqlite` / `workspace` | 4 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `drawer` | 2 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `drawer_pane` | 3 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `tab_shell` | 5 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `tab_pane` | 3 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `tab_arrangement` | 5 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `arrangement_layout_pane` | 4 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `arrangement_layout_divider` | 3 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `arrangement_minimized_pane` | 2 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `arrangement_drawer_view` | 3 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `drawer_view_layout_pane` | 6 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `drawer_view_layout_divider` | 5 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |
| `core.sqlite` / `drawer_view_minimized_pane` | 3 | Shared workspace authority candidate | WA-G1, WA-G2 | Candidate |

### Rows still needing a split or scope decision

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `core.sqlite` / `app_workspace_selection` | 3 | Navigation/preference scope pending; no automatic sharing | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `pane` | 20 | Split required; no whole-row move | RN01, RN04, RN05, WA-G1, WA-G2 | Hold |
| `core.sqlite` / `pane_content_terminal` | 4 | Split required; no whole-row move | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `pane_content_webview` | 4 | Split required; no whole-row move | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `pane_content_code_viewer` | 3 | Split required; no whole-row move | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `pane_content_payload` | 3 | Split required; no whole-row move | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `workspace_terminal_session_ownership` | 6 | Hold: legacy graph/Undo custody must split from execution identity and target lifecycle | WA-G1, WA-G2 | Hold |
| `core.sqlite` / `workspace_undo_close` | 11 | Hold: shared graph, device Undo and execution custody require a joint contract | RN04, RN05, WA-G1, WA-G2, WA-G3 | Hold |
| `core.sqlite` / `workspace_undo_close_member` | 3 | Hold: shared graph, device Undo and execution custody require a joint contract | RN04, RN05, WA-G1, WA-G2, WA-G3 | Hold |
| `local.sqlite` / `local_workspace_cursor` | 3 | Navigation/preference scope pending; no automatic sharing | RN04, WA-G3 | Hold |
| `local.sqlite` / `local_tab_cursor` | 4 | Navigation/preference scope pending; no automatic sharing | RN04, WA-G3 | Hold |
| `local.sqlite` / `local_arrangement_cursor` | 4 | Navigation/preference scope pending; no automatic sharing | RN04, WA-G3 | Hold |
| `local.sqlite` / `local_drawer_cursor` | 4 | Navigation/preference scope pending; no automatic sharing | RN04, WA-G3 | Hold |
| `local.sqlite` / `local_arrangement_drawer_cursor` | 5 | Navigation/preference scope pending; no automatic sharing | RN04, WA-G3 | Hold |
| `local.sqlite` / `local_repo_explorer_preferences` | 6 | Navigation/preference scope pending; no automatic sharing | RN04 | Hold |
| `local.sqlite` / `local_entity_recency` | 4 | Navigation/preference scope pending; no automatic sharing | RN03, RN05 | Hold |
| `local.sqlite` / `local_workspace_entity_recency` | 5 | Navigation/preference scope pending; no automatic sharing | RN05 | Hold |
| `local.sqlite` / `local_pane_activity` | 3 | Split required; no whole-row move | RN05 | Hold |

### Native UX-client state

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `local.sqlite` / `local_drawer_presentation` | 5 | UX-client local native state | RN04, WA-G3 | Local |
| `local.sqlite` / `local_window_state` | 16 | UX-client local native state | RN04, WA-G3 | Local |
| `local.sqlite` / `local_window_sidebar_collapsed_group` | 2 | UX-client local native state | RN04 | Local |
| `local.sqlite` / `local_editor_preferences` | 3 | UX-client local native state | RN04 | Local |

### Other private boundaries

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `local.sqlite` / `local_ipc_credential` | 5 | Private at actual verifying authority | CX-G6 | Private |
| `local.sqlite` / `local_recovery_provenance` | 6 | Private evidence at the affected store owner | No group in this bounded pass; see catalog sources | Private |
| `ipc/cli.sqlite` / `cli_store_identity` | 2 | Producer-local private state | CX-G3 | Private |
| `ipc/cli.sqlite` / `cli_outbox` | 6 | Producer-local private state | CX-G3 | Private |
| `ipc/cli.sqlite` / `cli_state` | 7 | Producer-local private state | No group in this bounded pass; see catalog sources | Private |

### Gateway derived state

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `in-memory search` / `search_document` | 6 | Gateway-local rebuildable derived state | RN06 | Local |
| `in-memory search` / `search_document_fts` | 2 | Gateway-local rebuildable derived state | RN06 | Local |

### Retained dormant features

| Current database / table | Columns | Proposed home / hold | Current groups | Copy |
| --- | ---: | --- | --- | --- |
| `local.sqlite` / `local_inbox_notification_preferences` | 9 | Retained/dormant; no target activation or export selected | RN07 | Hold |
| `local.sqlite` / `local_notification_inbox_item` | 36 | Retained/dormant; no target activation or export selected | RN07 | Hold |
| `local.sqlite` / `local_notification_inbox_collapsed_group` | 2 | Retained/dormant; no target activation or export selected | RN07 | Hold |

## Mixed-column allocations

All columns not listed here use the table's explicit default in the complete catalog. These allocations describe responsibilities; they do not rewrite a legacy row or preserve its key as a target identity.

### Named field-scope holds

Candidate homes below remain proposals where the field's subject or sharing scope is still open. Physical co-location cannot settle the following fields:

| Current fields | Meaning still to bind before target allocation/export |
| --- | --- |
| `pane.note`, `pane.is_pinned` | Logical-node versus actual native-pane subject, person/device scope and whether each field follows the selected portable composition. A shared-layout choice does not by itself settle every note/pin field. |
| `repo.note`, `repo.is_pinned`, `repo_tag.tag`, `worktree.note` | Resource identity remains Host-qualified; personal organization metadata needs its own audience and sharing meaning. The table's Host topology candidate is not an approved whole-row metadata allocation. `is_favorite` is an earlier migration spelling, renamed to `is_pinned` in the current schema. |
| Local workspace/tab/arrangement/drawer cursor fields | Separate logical arrangement selection from actual focus/responder/viewport. One local persistence snapshot is evidence of its current write boundary, not a selection that every cursor is native-only or shared. |

These explicit field holds clarify the [shared-client-state gaps](../10-swift-client/shared-client-state-design.md) and existing client-read needs; they choose no new sharing policy or target table and leave the 86-table/597-column census unchanged. Selected completed-agent viewed state remains distinct from still-open annotation/review-file/context-notice marker families.

### repo

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `is_pinned` | Hold: personal repository pin scope/audience and authority home remain unresolved; resource identity stays Host-qualified |
| `note` | Hold: repository note scope/audience and authority home remain unresolved; topology co-location does not allocate it |

### worktree

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `note` | Hold: worktree note scope/audience and authority home remain unresolved; resource identity stays Host-qualified |

### repo_tag

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `tag` | Hold: repository tag scope/audience and authority home remain unresolved; topology co-location does not allocate it |

### pane

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `id` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `workspace_id` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `content_type` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `note` | Hold: logical-node/native-pane subject and person/device sharing scope remain unresolved; shared-layout selection alone does not allocate this field |
| `kind` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `parent_pane_id` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `created_at` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `updated_at` | Shared logical composition candidate; legacy pane identity must split from execution and native view |
| `is_pinned` | Hold: logical-node/native-pane pin meaning and person/device sharing scope remain unresolved |
| `execution_backend` | Execution/source Host for applicable content variant; other variants need their own qualified association |
| `launch_directory` | Execution/source Host for applicable content variant; other variants need their own qualified association |
| `cwd` | Execution/source Host for applicable content variant; other variants need their own qualified association |
| `checkout_ref` | Execution/source Host for applicable content variant; other variants need their own qualified association |
| `title` | Split user/logical label from source-observed execution or native title; variant semantics not yet finalized |
| `facet_repo_id` | Host-local derived observation with its topology/availability predicate; never clear E25 content because another Host row is absent |
| `facet_worktree_id` | Host-local derived observation with its topology/availability predicate; never clear E25 content because another Host row is absent |
| `residency_kind` | Hold: separate logical close/Undo, execution custody and actual native residency before allocation |
| `pending_undo_expires_at` | Hold: separate logical close/Undo, execution custody and actual native residency before allocation |
| `orphan_reason_kind` | Hold: separate logical close/Undo, execution custody and actual native residency before allocation |
| `orphan_worktree_path` | Hold: separate logical close/Undo, execution custody and actual native residency before allocation |

### pane_content_terminal

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `pane_id` | Shared logical reference needs distinct execution/native identities |
| `provider` | Execution Host backend association |
| `lifetime` | Hold: execution lifetime must remain independent of view lifetime |
| `zmx_session_id` | Execution Host-qualified backend association; not an attachment or connection ID |

### pane_content_webview

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `pane_id` | Shared logical content reference candidate |
| `url` | Portable content/navigation intent needs exact shared-navigation contract |
| `title` | Split saved content label from actual native page title |
| `show_navigation` | UX-client presentation candidate; exact portability remains explicit |

### pane_content_code_viewer

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `pane_id` | Shared logical content reference candidate |
| `file_path` | Addressed Host source reference; raw path is not global identity |
| `scroll_to_line` | Navigation intent; distinguish initial requested target from actual viewport |

### pane_content_payload

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `pane_id` | Shared logical content reference candidate |
| `payload_kind` | Kind-qualified contract selects the actual owner |
| `payload_json` | Decode each existing variant; no blanket JSON export or owner |

### workspace_terminal_session_ownership

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `session_id` | Execution Host-qualified backend association after identity split; current row remains in the joint hold |
| `process_identity` | Actual execution Host process/backend evidence; no restart adoption inferred |
| `cleanup_state` | Legacy graph/Undo-driven cleanup; not selected target execution lifecycle under R5/R6 |
| `cleanup_requested_at` | Legacy cleanup record; part of joint split/retention hold |
| `cleanup_completed_at` | Legacy cleanup record; part of joint split/retention hold |
| `last_cleanup_error` | Legacy cleanup/error record; private audience and split hold |

### sessions_source

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `last_cursor` | Private Host source checkpoint; excluding from copies may require target record split |

### annotation_message

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `viewed_saved_revision` | Subject Host candidate; extra shared-marker family scope remains with Sun |

### annotation_message_draft

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `active_edit_token` | Host edit-admission custody; do not grant another peer by copying the token |

### annotation_output_attempt

| Current column | Proposed meaning / owner or hold |
| --- | --- |
| `destination_path` | Host workflow record with addressed destination/error audience; effect occurs separately at actual destination |
| `effect_error` | Host workflow record with addressed destination/error audience; effect occurs separately at actual destination |
| `cleanup_error` | Host workflow record with addressed destination/error audience; effect occurs separately at actual destination |

## What the accounting proves

This view accounts for **86 unique logical tables and 597 columns**, with 50 explicit column overrides. It reuses the source census; it is not a new installed-data scan. Each table has a separate owner/hold, copy disposition and transaction reference. The 35 expanded value containers and 14 non-SQL families remain in the complete catalog; no claim is made that all of their variant-specific fields now have final homes.

The next schema design must close every hold and selected field/container split, preserve required integrity meaning, define audience/retention/recovery and pass actual engine admission. The current immutable-UUIDv7, trigger and source-form evidence remains in [schema prerequisites](research/schema-prerequisites.md). Inventory coverage is not migration readiness or product proof.
