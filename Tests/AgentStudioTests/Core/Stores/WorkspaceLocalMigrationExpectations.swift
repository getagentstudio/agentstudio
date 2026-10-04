// Exact migration inventories shared by the local schema regression suite.
let expectedBootRequiredLocalMigrationIdentifiers = [
    "001_create_application_local_schema",
    "002_replace_recent_targets_with_entity_recency",
    "003_invert_sidebar_group_memory",
    "004_remove_persisted_pull_request_counts",
    "005_move_repo_grouping_to_window_sidebar_memory",
    "006_add_repository_local_activity_facts",
    "006_create_worktree_annotation_schema",
    "007_add_worktree_annotation_message_handled",
    "008_add_worktree_annotation_message_viewed_revision",
    "009_add_worktree_annotation_reviewed_subject_evidence",
    "010_remove_worktree_annotation_workspace_provenance",
    "007_add_per_screen_sidebar_organization",
    "015_add_panes_drawer_visibility",
    "015_create_local_drawer_presentation",
]

let expectedFullLocalMigrationIdentifiers =
    expectedBootRequiredLocalMigrationIdentifiers
    + [
        "011_create_sessions_ingestion_schema",
        "020_sessions_status_and_replay",
        "021_pane_context_current_values",
        "022_pane_context_messages",
        "023_pane_context_write_order",
        "024_pane_context_answer_positions",
        "025_pane_context_retirement",
        "012_create_ipc_credential_schema",
        "013_create_opaque_pane_credential_records",
        "014_ipc_credentials_pane_only",
        "019_create_pane_context_cli_outbox_cursor",
    ]
