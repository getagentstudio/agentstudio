# Current use of every catalogued table

**All 86 current logical table names are accounted for by their read, write, operational or retained-source purpose. This does not select 86 tables for replication.** The [view dependency map](query-data-dependencies.md) explains the consumer boundaries; this index lets a reader locate each table without mistaking credentials, custody, client preferences or disposable search for shared domain state.

Source baseline: AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. The existing [catalog](data-catalog.json) supplies 86 table identities and 597 named columns; the [structured use index](table-use-index.json) connects each identity to the named source closures and their limits. Backing-file names below describe the current code. Target units, audience, export membership, retention, client scope and schemas remain unselected. Installed rows, migrations and distributed behavior have not been observed.

## What the coverage means

The sidebar, Sessions/context and annotation read maps name 71 distinct table identities, including conditional children, wider snapshot hydration and auxiliary support. The fifteen identities outside that read/support union are classified separately below. Some already occur as maintenance write targets; “outside the read union” does not mean uninspected or unused.

| Current purpose outside that read union | Tables | Why a read copy is insufficient |
| --- | --- | --- |
| Execution custody and recovery | `workspace_terminal_session_ownership`, `local_recovery_provenance` | Cleanup eligibility/effect reconciliation and a local replacement witness affect actual service admission. Receiving rows transfers neither destructive custody nor a receiver's recovery acknowledgement |
| Protocol and producer bookkeeping | `pane_epoch_claim`, `local_ipc_credential`, `pane_context_cli_outbox_cursor`, `cli_store_identity`, `cli_outbox`, `cli_state` | Claim response, current write admission, verifier scope, handled prefix, queued intent and printed progress are different facts. They are not successful domain operations |
| Active native preferences | `local_drawer_presentation`, `local_editor_preferences` | Stored intent joins actual composition, geometry or installed targets. Ordinary reads and boot/resolution side effects have different boundaries |
| Retained Inbox source | `local_inbox_notification_preferences`, `local_notification_inbox_item`, `local_notification_inbox_collapsed_group` | Current boot source explicitly retires ingestion/presentation. Retained schema/functions do not select revival, removal or export; no located caller is a bounded search result |
| Disposable search | `search_document`, `search_document_fts` | A current search can install/rebuild its private in-memory index before reading. The paired index is derived from the admitted document set and is not another domain truth |

## Read the table index

“Used by” records named current dependencies, not a minimal query schema or proposed service owner. The same table can support a passive read and a separate maintenance/acknowledgement write. Open its source record for exact column groups, read/write closures, production wiring, conditional paths and gaps. Complete column enumeration and source-key prerequisites remain in the [catalog](data-catalog.json) and [schema analysis](schema-prerequisites.md).

## `core.sqlite`

| Current table | Used by / current purpose | Source record |
| --- | --- | --- |
| `workspace` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `app_workspace_selection` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `watched_path` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `repo` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `worktree` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `repo_tag` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `unavailable_repo` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `unavailable_worktree` | Repository topology and intent | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `pane` | Pane activity and retain membership; Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `pane_content_terminal` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `pane_content_webview` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `pane_content_code_viewer` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `pane_content_payload` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `drawer` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `drawer_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `tab_shell` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `tab_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `tab_arrangement` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `arrangement_layout_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `arrangement_layout_divider` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `arrangement_minimized_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `arrangement_drawer_view` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `drawer_view_layout_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `drawer_view_layout_divider` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `drawer_view_minimized_pane` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `workspace_terminal_session_ownership` | Execution custody; guarded cleanup and effect reconciliation | [custody/recovery](../../../research/evidence/2026-10-17-daemon-capability-placement/custody-recovery-table-closure.json) |
| `workspace_undo_close` | Pane activity and retain membership | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `workspace_undo_close_member` | Pane activity and retain membership | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |

## `local.sqlite`

| Current table | Used by / current purpose | Source record |
| --- | --- | --- |
| `sessions_conversation` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_operation` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_pane_binding` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_source` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_evidence` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_provider_question` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `sessions_provider_question_option` | Sessions evidence/status input; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_state` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_state_action` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_event` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_action` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_event_action` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_choice` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_property` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_required` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_property_choice` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_request_answer_value` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_write_order` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_epoch_claim` | Claim replay and writer-order allocation | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) · [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |
| `pane_answer_position` | Sessions/context query or maintenance | [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `pane_retirement` | Compact context and maintenance; Sessions/context query or maintenance | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) · [context](../../../research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) |
| `local_ipc_credential` | Durable credential verifier/scope continuity | [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |
| `pane_context_cli_outbox_cursor` | Handled notice-source prefix | [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |
| `local_workspace_cursor` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_tab_cursor` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_arrangement_cursor` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_drawer_cursor` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_arrangement_drawer_cursor` | Wider graph/content/cursor hydration | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_drawer_presentation` | Active native drawer preference; boot import | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |
| `local_window_state` | Sidebar/filter/collapse/sort memory | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_window_sidebar_collapsed_group` | Sidebar/filter/collapse/sort memory | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_editor_preferences` | Active native editor preference; resolution may heal bookmark | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |
| `local_repo_explorer_preferences` | Sidebar/filter/collapse/sort memory | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_inbox_notification_preferences` | Retained Inbox preference helpers; no external production caller located | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |
| `local_entity_recency` | Auxiliary recency observation | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_workspace_entity_recency` | Auxiliary recency observation | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `cache_metadata` | Saved enrichment and runtime-status boundary | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `cache_repo_enrichment` | Saved enrichment and runtime-status boundary | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `cache_worktree_enrichment` | Saved enrichment and runtime-status boundary | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_repository_activity` | Repository activity and coverage | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_repository_activity_cursor` | Repository activity and coverage | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `local_pane_activity` | Pane activity and retain membership | [sidebar](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) |
| `annotation_session` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_thread` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_message` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_message_draft` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_output_attempt` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_output_attempt_message` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `annotation_output_event` | Annotation query/decode | [annotations](../../../research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) |
| `local_recovery_provenance` | Local replacement witness and explicit acknowledgement | [custody/recovery](../../../research/evidence/2026-10-17-daemon-capability-placement/custody-recovery-table-closure.json) |
| `local_notification_inbox_item` | Retired Inbox persistence; retained fetch can prune malformed rows | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |
| `local_notification_inbox_collapsed_group` | Retired Inbox presentation memory | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |

## `ipc/cli.sqlite`

| Current table | Used by / current purpose | Source record |
| --- | --- | --- |
| `cli_store_identity` | Producer-file identity and channel admission | [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |
| `cli_outbox` | Producer notice source and cleanup | [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |
| `cli_state` | Producer write reservation and printed-answer progress | [CLI/admission](../../../research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) |

## `in-memory search`

| Current table | Used by / current purpose | Source record |
| --- | --- | --- |
| `search_document` | Private in-memory search projection | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |
| `search_document_fts` | Private in-memory FTS derivative | [native/Inbox/search](../../../research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) |

## Extraction constraints

- Preserve the writer's transaction predicates and required private bookkeeping while selecting the replication audience separately. Credentials and current authorization are separate; a copied verifier is not permission.
- Keep retained claim replies separate from current writer epoch/counter admission. Retrying a claim and replaying a payload have different consequences.
- Preserve notice intake's source identity and handled disposition. Handled may include refused/malformed entries; producer dedup differs from server semantic-intent dedup.
- Keep client preference meaning separate from its future persistent home. A saved editor identifier cannot establish an installed app or successful external open.
- Treat actual native presence, backend process evidence and local recovery acknowledgement as their own inputs. Current custody/recovery rows cannot be copied into a new owner and interpreted as a new grant.
- Choose any search relocation from its real document/capability/native-context inputs. A derived SQL index does not need faithful replication merely because it uses SQLite.

The named-source coverage closes table accounting at this depth. It does not close every operation, column use, permission race, provider transition, cascade/trigger, runtime liveness or future source-to-copy-to-client proof. The proposed [Host/Gateway/native processing split](../../09-gateway-cli/prepared-view-boundaries.md) and open data profiles retain their existing decision homes.
