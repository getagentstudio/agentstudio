# Adopt the newer ZMX in AgentStudio

[Open the guided HTML reader](index.html) · [Return to qualification](../README.md) · [Executed experiments](../../../explainer/progress.html)

## Read the design

| Document | Reader question |
| --- | --- |
| [Shared Requirements](../../../user-requirements.md#requirement-rows), especially U24 and S31 | What did the owner authorize? |
| [Specification](specification.md) | What must the upgraded app do, and what must it refuse? |
| [Program Design](program-design.md) | Which existing owners change, and how do their calls remain safe? |
| [Verification Design](verification-design.md) | What observations will distinguish a working integration from a pin-only update? |

## Follow one terminal

1. [The user outcome](specification.md#what-this-step-delivers).
2. [A fresh native attachment](program-design.md#one-terminal-from-the-app-to-zmx).
3. [Versioned control and cleanup](program-design.md#one-cleanup-request-through-validation).
4. [Wrong versions, replacement processes and uncertain endings](program-design.md#failure-and-overlap).
5. [Proof through the delivered app](verification-design.md#shared-observations).

## Understand the boundary

1. [Worktree isolation and surviving old sessions](specification.md#c4-worktree-boundary).
2. [Internal ownership and the wire shape](program-design.md#where-each-entity-lives).
3. [What remains outside this integration](specification.md#what-this-step-does-not-deliver).

For the broader project, use the [feature hierarchy](../../../explainer/features.html), [migration sequence](../../../explainer/sequence.html) and [terminal-runtime design](../../../designs/04-terminal-runtime/README.md).
