# Integratable increment specifications

These draft profiles turn the topic contracts into usable outcomes. Read [delivery increments](../delivery-increments.md) for the proposed MVP/order and [DS01–DS11](../designs/README.md) for domain ownership. All profiles reuse the same [Requirements](../user-requirements.md), global entities and R/C/V meanings. They do not create separate requirement copies or replace the fifteen capability contracts.

| Profile | Usable outcome | Input contract dependency |
| --- | --- | --- |
| [I0 Qualification](00-qualification/specification.md) | Checked feasibility for the remote-terminal slice | Source pins, selected observation profiles and safe isolated fixtures |
| [I1 Remote-terminal MVP](01-remote-terminal/specification.md) | A real remote ZMX session inside AgentStudio, with separate detach and terminate | I0's relevant gates; selected session/control/trust/native path |
| [I2 Autonomous agents and context](02-agents-context/specification.md) | Supported agent inputs, facts and asks work without Swift or any Gateway (macOS or iOS) | Host execution and selected authority/data transactions |
| [I3 Repository and Git reads](03-repository-reads/specification.md) | Remote sidebar, repository facts and bounded diff/content | Target/path/currentness and read/publication contracts |
| [I4 Git mutations and fork](04-git-worktrees/specification.md) | Complete selected Git/worktree mutations and Linux fork | Git reads/identity plus effect/cancellation/platform policy |
| [I5 Reviews and output](05-review-output/specification.md) | Remote review/annotation workflow with truthful destination effects | Content/revision/transaction and native destination contracts |
| [I6 Replication and selected sharing](06-replication/specification.md) | Faithful copies/refill and prepared state under the chosen sharing scope | Selected units, schemas, permissions, central lease profile |
| [I7 Clients and operation](07-clients-operation/specification.md) | Supported phone/MCP/CLI/concurrency and operational release profiles | The actual capabilities exposed to each client and platform |

These are proposed increment scopes, not accepted release dates or implementation plans. Each profile identifies the visible result, app integration seam, normal/failure boundary and proof/dependency gaps. Its missing owner meaning must be settled before its Program Design and implementation plan can be called ready. Source investigation can proceed independently. Later profiles remain project obligations; a smaller MVP is not a waiver.
