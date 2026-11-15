# Tasks versus delegation: models and open questions

Side-conversation note for the main agent, 2026-11-01. The owner requested saving this discussion. This is a discussion handoff, not an adopted specification, implementation plan or authorization to change the main work.

## Owner's focus

- Compare T3 Code's task/delegation system with the loosely coupled board system, including pros, cons and when each is useful.
- Explain the model of tasks versus delegation, preserving both as useful concepts.
- “How does an agent communicate it has finished a task. Or ask about a task that it wants done?”
- Latest clarification of the note's subject: “Tasks vs delegation and model of both.”

## Source-backed observations from this side conversation

At T3 Code revision `3fd2b855c5c6b9169cdfe3733b34011c1c5ed4b7`, delegation is an actual execution-oriented task system, not simply a message asking another agent to work:

- `delegate_task` creates a tracked task associated with parent and child execution; returns a task ID.
- Task states include queued, running, waiting, completed, failed, cancelled and interrupted.
- Completion can wake the parent or return through a waiting tool call. Status/result delivery and cancellation have explicit interfaces.
- Remote delegation launches a child thread on a linked environment and records its relationship to the parent-side task.

Decisive source locations in `/Users/shravansunder/code/opensource/agent-workspaces/t3code/`:

- `apps/server/src/mcp/toolkits/orchestrator/tools.ts:86` — delegation/status/cancel interfaces.
- `apps/server/src/mcp/OrchestratorMcpService.ts:2400` — delegated task command, parent identity and resulting child/task projection.
- `apps/server/src/peer/RemoteDelegation.ts:261` — remote launch and parent-side task association.
- `packages/contracts/src/orchestratorMcp.ts:148` — task outcome vocabulary.

The inspected Router board design already defines real tasks, workstreams, dependencies, roles and work history; “loosely coupled” does not mean free-text messages only. Reference: `/Users/shravansunder/code/projects/codex-router/docs/specs/2026-10-04-board-orchestration-design/spec-1-board-and-contracts.md:106`. That is a design source, not a runtime verification claim. No builds or runtime tests ran in this side conversation.

## Proposed conceptual model — not yet confirmed by owner

| Concept | Proposed meaning |
| --- | --- |
| Task | Durable work to accomplish, independent of the current worker or session |
| Execution attempt | One agent/session trying to fulfil that task; may succeed, fail or be interrupted |
| Delegation | A relationship that requests/assigns work and connects its execution to a delegating actor; parent/child execution is one form |
| Message | Communication that does not inherently create a task, authorize execution or settle an outcome |

A task could survive several attempts and worker handoffs. One attempt could delegate bounded investigations. A task/subtask decomposition describes work; an agent execution tree describes who is running it. Their relationship needs an explicit contract rather than an assumption that both trees are identical.

The suggested combination was durable board tasks plus controlled execution/delegation. Execution outcomes feed the task system; they do not silently become acceptance of the durable obligation. This is the side assistant's recommendation, not an owner selection or a requirement to add new records.

## Gains and costs discussed

- Parent/child delegation suits bounded parallel investigations: direct launch/control, result routing and completion wakeup. Costs include parent/child coupling, cancellation scope and additional rules for reassignment or independent peers.
- Shared board coordination suits longer work across agents, sessions and review steps: stable work identity, dependencies and retained evidence. Costs include explicitly connecting work records to execution; a board status alone neither supervises a process nor proves the result.
- Combining them needs one authoritative owner for each truth. A run ending, a result being delivered, and a task being accepted as done must not become competing writers of one ambiguous status.

## Questions for the main discussion

1. **Reporting completion:** where does an agent submit the task/attempt identity, outcome and result/evidence? Who records it, who accepts it, and who is notified? Distinguish submission, durable recording, notification delivery and task acceptance.
2. **Requesting work:** does the agent create a durable task request, assign an existing task, delegate an execution, or send a proposal requiring acceptance? These should not be inferred from an ordinary message. Also clarify whether “ask about a task” includes questions/clarification on an existing task.
3. **Authority:** who may assign, accept, cancel, reassign or close work? Does cancellation stop one attempt, its descendants, or the durable task? Parentage alone should not be assumed sufficient authority.
4. **Loose coupling:** can agents request work from existing independent peers as well as newly created child sessions? Can the work continue after the requester disconnects or finishes?
5. **Relationships:** may one task have successive or concurrent attempts, and how do delegated results contribute to it? Preserve task completion versus execution completion explicitly.

An illustrative direction is a structured completion report to the task owner, followed by durable recording and notifications, and a structured work request that can be accepted/refused before execution. This is only a discussion starting point; no event schema, transport, storage placement, retry policy or acceptance rule was selected.

## Boundary

The main agent should use this note to clarify meaning with the owner before changing governing contracts. The side conversation did not contact agents, modify product code, change Git state, or select a deployment architecture. Its sole requested mutation is this note.
