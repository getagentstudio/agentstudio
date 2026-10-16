# Claude Code 2.1.286 recorded hooks

These JSON documents are extracted from the S0/S0b capture files under
`tmp/workspace-control/prb-provider-traces/scratch/claude-traces/*.jsonl.log`
(2026-09-30). Field shapes/types, event names, call identities and required
failure categories are captured. Paths and prompt/tool/form prose are scrubbed
to neutral fixture values; serialization is normalized as JSON. Question
scrubbing is identical across the captured opening, permission and completion.

The three `AskUserQuestion.*` payloads belong to the same recorded session,
with the same Pre/Post `tool_use_id`. The PermissionRequest raw payload is
in `scratch/claude-traces/PermissionRequest.jsonl.log`; the aggregate S0b
report describes it but omitted its JSON. Stop is read from its raw capture
because the aggregate log contains expanded string newlines.

Elicitation and ElicitationResult have no elicitation ID. These fixtures
must never be changed to manufacture one. Codex has no new recorded hook
payloads in S0; its existing source-derived fixtures remain separately
identified in `codex-0.154/`.
