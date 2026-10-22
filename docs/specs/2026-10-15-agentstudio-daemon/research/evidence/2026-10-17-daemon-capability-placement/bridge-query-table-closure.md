# Annotation query dependencies and transaction boundaries

Source-only at AgentStudio 624300332f5e50f7bb8cbb9fc786d5e5b4a3d462. Five named query/decode families, not a complete Bridge/SQL audit. Root inspected the deciding sources and authored this evidence. No target copy membership, audience, schema or runtime proof is selected.

## annotation session discovery

Consumer: Session catalog and demanded annotation workflow.

Tables / meaningful fields:
- `annotation_session`: `id`, `repository_id`, `worktree_id`, `lifecycle`, `source_relationship`, `accepted_source_fingerprint_json`, `accepted_reviewed_subject_json`, `semantic_revision`, `created_at`, `updated_at`, `completed_at`

Named closure: WorktreeAnnotationSQLiteRepository.discoverSessions → databaseWriter.read → loadSessions; ordered by created_at/id. Foreign-living candidates separately restrict repository/worktree/lifecycle/source relationship.

Extra-SQL state: Service availability/recovery admission; current source generation and native placement are not established by this list.

Writes in that named read closure: none observed. Storage opening/availability and other service workflows remain separate.

A pure row/decode read inside the named repository closure. Actual service/datastore opening/availability is separate; no exported schema/audience or target query API is selected.

Sources: [WorktreeAnnotationSQLiteRepository.swift:145](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository.swift:145), [WorktreeAnnotationSQLiteRepository.swift:194](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository.swift:194), [WorktreeAnnotationServiceActor.swift:87](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationServiceActor.swift:87)

## coherent demanded annotation detail

Consumer: File/Review annotation projection SQL input and source requirements.

Tables / meaningful fields:
- `annotation_session`: `identity/source/lifecycle/revision fields`
- `annotation_thread`: `identity/session/scope/resolution/origin/ordinal/revision fields`
- `annotation_message`: `identity/thread/author/saved_body/saved_revision/status/handled/viewed_saved_revision/revisions`
- `annotation_message_draft`: `message_id`, `active_edit_token`, `body`, `draft_revision`, `updated_at`

Named closure: fetchProjectionSnapshot performs loadSessions and all demanded loadSessionDetail calls inside one databaseWriter.read closure. Demanded session IDs must be in that worktree list. Detail loads session/threads/messages, and decodeMessage reads each draft.

Extra-SQL state: Service projectionRevision/recoveryState captured before await and checked afterward. Descriptor query additionally resolves source generation, captures actual source refresh/placement requirements, revalidates generation, and reserves query/page/worker authority.

Writes in that named read closure: none observed. Storage opening/availability and other service workflows remain separate.

Copied rows could supply selected coherent workflow read input only if all required rows/values and permissions are supplied under a target read contract. SQL alone cannot rebuild current runtime projection/recovery token, actual Git/file placement or native worker/publication authority. This is not permission to export all draft fields.

Sources: [WorktreeAnnotationSQLiteRepository.swift:169](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository.swift:169), [WorktreeAnnotationSQLiteRepository+Loading.swift:439](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Loading.swift:439), [WorktreeAnnotationSQLiteRepository+Loading.swift:522](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Loading.swift:522), [WorktreeAnnotationServiceActor.swift:92](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationServiceActor.swift:92), [BridgePaneProductWorktreeAnnotationProjectionSource.swift:107](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationProjectionSource.swift:107)

## annotation projection message output

Consumer: Current Bridge finite projection record.

Tables / meaningful fields:
- `annotation_message`: `saved_body`, `saved_revision`, `semantic_revision`, `handled`, `author_kind`, `status`, `created_at`, `ordinal`
- `annotation_message_draft`: `active_edit_token`, `body`, `draft_revision`
- `annotation_session`: `id`, `semantic_revision`
- `annotation_thread`: `id`, `semantic_revision`

Named closure: BridgeProductWorktreeAnnotationMessageEntry derives attention from current domain message, includes draft(activeEditToken,body,revision), saved body/revision and message/session/thread revision/identity fields.

Extra-SQL state: Thread placement/context, sourceGeneration, page snapshot/recovery header, descriptor/query lifetime and native consumer currentness.

Writes in that named read closure: none observed. Storage opening/availability and other service workflows remain separate.

Current product projection already includes draft/edit values for its admitted local workflow. That local exposure neither selects distributed audience nor makes edit token alone sufficient authority: runtime ownership registry separately checks token→ownerGeneration.

Sources: [BridgeProductWorktreeAnnotationProjectionContracts.swift:585](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductWorktreeAnnotationProjectionContracts.swift:585), [BridgeProductWorktreeAnnotationProjectionRecordCursor.swift:4](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductWorktreeAnnotationProjectionRecordCursor.swift:4), [WorktreeAnnotationServiceActor+EditOwnership.swift:17](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationServiceActor+EditOwnership.swift:17)

## immutable output attempt inspection

Consumer: Output metadata/finite exact-byte source; effect reconciliation read.

Tables / meaningful fields:
- `annotation_output_attempt`: `id`, `session_id`, `output_kind`, `state`, `format_version`, `content_type`, `snapshot_json`, `exact_bytes`, `destination_path`, `repeated_from_attempt_id`, `effect_error`, `cleanup_error`, `created_at`, `updated_at`
- `annotation_output_attempt_message`: `message_id`, `expected_saved_revision`, `batch_ordinal`
- `annotation_output_event`: `id`, `attempt_id`, `event_kind`, `created_at`

Named closure: inspectOutputAttempt calls databaseWriter.read → loadPreparedOutput; reads attempt, ordered exact membership and event, decodes stored snapshot at format version.

Extra-SQL state: Service read availability; finite output source issues bounded descriptor, consumes it once, rereads/compares immutable attempt and returns bytes/hash. Actual clipboard/file effect owner and user visibility are outside this read.

Writes in that named read closure: none observed. Storage opening/availability and other service workflows remain separate.

A whole attempt table includes exact_bytes, snapshot_json, errors and destination_path, not just the selected history summary. Target export/privacy/history/custody must be chosen explicitly. Query/descriptor success does not perform or prove output.

Sources: [WorktreeAnnotationSQLiteRepository+Output.swift:323](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Output.swift:323), [WorktreeAnnotationSQLiteRepository+Output.swift:612](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Output.swift:612), [BridgePaneProductWorktreeAnnotationOutputSource.swift:28](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationOutputSource.swift:28), [BridgePaneProductWorktreeAnnotationOutputSource.swift:45](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationOutputSource.swift:45)

## bounded output history summary

Consumer: Annotation output history and canMarkNotHandled presentation.

Tables / meaningful fields:
- `annotation_output_attempt`: `id`, `session_id`, `output_kind`, `state`, `repeated_from_attempt_id`, `created_at`, `updated_at`
- `annotation_output_attempt_message`: `attempt_id`, `message_id`, `expected_saved_revision`
- `annotation_message`: `id`, `handled`, `saved_revision`

Named closure: fetchOutputHistory uses one databaseWriter.read query joining attempts/membership/current message, excludes cancelled, groups by attempt, orders newest first, applies limit. can_mark_not_handled depends on succeeded state and current handled matching saved revision.

Extra-SQL state: Service availability and maximum-history-summary bound. A later clearOutputHandled is a separate revision-fenced write, not an effect of reading this boolean.

Writes in that named read closure: none observed. Storage opening/availability and other service workflows remain separate.

History is not append-only event replay and canMarkNotHandled is state-dependent, not a grant. All joined rows must come from the selected coherent read/position. Unrelated latest positions or partial joins cannot fabricate a complete summary.

Sources: [WorktreeAnnotationSQLiteRepository+Output.swift:511](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Output.swift:511), [WorktreeAnnotationServiceActor.swift:486](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationServiceActor.swift:486)

## Write counterexample

Output finalization is a separate writer transaction; inserts event, sets attempt succeeded/destination, marks matching revisions handled and advances session. Never replay from copy invalidation.

## Search and proof limits

- Guessed +Projection.swift/+Messages.swift/+Sessions.swift filenames were absent; bounded rg file inventory located actual repository Loading/CatalogLoading files. No absence-of-feature claim adopted.
- Shell glob for annotation projection files had no match; rg --files found WorktreeAnnotationProjection* actual files.

Current named read closures and deciding wrappers/decoders inspected. DatabaseWriter.read observed as source API usage, not new external-library snapshot proof. Datastore preparedLocalRepository internals not retraced. No runtime, copy apply, native effect, schema migration or distributed permission proof.
