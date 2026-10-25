# Ask forms and approval: Lead notes (read-only Explore lane, 2026-10-24; re-verify anchors before the Program Design)

- `AskReason.approval` already exists. Today's approval is `agentstudio ask --reason approval --choice allow,deny`. What's new is a FORM kind plus a `{decision, reason}` answer value.
- The CLI builds only choice (single-select) and freeText. Elicitation and multi-choice are reachable only through raw IPC.
- The only form renderer is the `MessagesPopover` row (`AskAnswerForm`, pane location only). The card has no ask block; there is no "Resolved" group in code.
- Name collision to avoid: `AgentStudioIPCHumanApprovalPort` / `PermissionBroker` are IPC *permission* approvals, unrelated to pane asks.
- Pane-context IPC methods (`pane.message.send/ask`) are NOT AppCommands, so there is no `ipcSpec`. The UI needs `LocalActionSpec` cases for Approve / Deny.
- Persistence: a new `form_kind='approval'` needs no migration. The answer could use `answer_kind='decision'` with `answer_text` = reason; the decision column choice may need a migration, which is an owner question.
- About 14 exhaustive form switches and about 11 answer switches to extend (full list in the lane report: AgentMessageDetail:83/106, PaneContextAdmission:14/48/90/109, Storage+Forms, Storage+Answers, MessageProjection:79 allow-list, IPC mapping both ways, `IPCPaneAskForm` / `IPCPaneAskAnswerValue`, popover shaping, AskFormModel, AskAnswerForm:21, AnswerParsing:20, CLI parse or a new `IPCModelCallVariant.approval`, test helpers).
- Owner decision needed: a new CLI verb `agentstudio approval` (new `IPCModelCallVariant`, help, catalog, skill "seven verbs" → eight) versus `ask --form approval`.
