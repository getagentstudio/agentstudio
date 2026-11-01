# Hook and pane prior art

Historical source findings from the October 2026 identity investigation.
These do not establish current compatibility with every provider version.

## Herdr's explicit join

At [Herdr commit `5608de0608918aba2f9d501e7793b984a0ca9cfa`](https://github.com/herdrdev/herdr/tree/5608de0608918aba2f9d501e7793b984a0ca9cfa),
the terminal launch environment supplies a pane address and server socket.
A provider SessionStart hook combines that context with its native conversation
ID and submits both to the receiver. The hook does not derive a pane address
from its own PID.

Decisive source paths:

- [Pane environment](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/pane.rs#L184).
- [Claude hook](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/integration/assets/claude/herdr-agent-state.sh#L34).
- [Codex hook guards](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/integration/assets/codex/herdr-agent-state.sh#L51).
- [Receiver](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/app/api/panes.rs#L1599)
  and [replacement rules](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/terminal/state.rs#L1385).

## Limits that matter for AgentStudio

An inherited pane address describes launch context. Shared-server execution,
later attachment and nested multiplexers can separate it from the current
viewer. Status and process presence can corroborate a report without supplying
an unreported client/conversation association.

Herdr's [background-job tracker](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/pane/background_agent.rs#L1)
retains an already identified process across shell job-control changes. Its
[remote attach path](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/remote/attach.rs#L54)
connects to an explicitly named remote Herdr session. Neither is evidence of a
universal lookup from an unrelated backend PID to the pane displaying a native
conversation.

The [current research report](../agent-location.html) separates launch origin,
backend identity, exact visible selection and the source of each observation.
The [earlier registration proposal](launch-identity-proposal.html) is preserved
as discussion rather than an adopted contract.
