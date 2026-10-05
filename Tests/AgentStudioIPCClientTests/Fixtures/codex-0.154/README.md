# Codex 0.154 hook payload fixtures

Schema-derived, not captured from a live run. Each file is built from the
serialized `*CommandInput` struct in `codex-rs/hooks/src/schema.rs` at
`openai/codex` tag `rust-v0.154.0`, keeping that struct's exact field names and
its required/optional split:

| File | Struct | schema.rs |
| --- | --- | --- |
| `session-start.json` | `SessionStartCommandInput` | 499-513 |
| `session-end.json` | `SessionEndCommandInput` | 515-523 |
| `user-prompt-submit.json` | `UserPromptSubmitCommandInput` | 567-586 |
| `permission-request.json` | `PermissionRequestCommandInput` | 301-322 |
| `pre-tool-use.json` | `PreToolUseCommandInput` | 278-300 |
| `subagent-start.json` | `SubagentStartCommandInput` | 549-565 |
| `subagent-stop.json` | `SubagentStopCommandInput` | 606-625 |
| `stop.json` | `StopCommandInput` | 588-604 |
| `interrupt.json` | `InterruptCommandInput` | 627-640 |
| `post-tool-use.json` | `PostToolUseCommandInput` | 323-346 |

Three facts these fixtures encode on purpose:

- `SessionStart` and `SessionEnd` carry no `turn_id`.
- `PermissionRequest` carries no `tool_use_id` and no request identifier of any
  kind; only `PreToolUse` and `PostToolUse` carry `tool_use_id`. The CLI mints a
  fresh UUIDv7 `occurrenceId` for each invocation and leaves `requestId` unset;
  `tool_name` does not identify a permission request.
- The subagent events carry a required `agent_id` and no `tool_use_id`, so
  `agent_id` is what separates two subagents inside one turn.

A live capture from a real Codex run is still owed; it belongs with the
end-to-end provider proof, not here.
