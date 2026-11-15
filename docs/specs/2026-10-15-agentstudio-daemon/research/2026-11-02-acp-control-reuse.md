# ACP reuse update: shared execution and distinct clients

This research note retains its November 2 baseline and adds the November 5 source refresh below. It is evidence for the daemon design, not an adopted Host deployment or runtime result.

## November 5: the upstream interface design has advanced

The Router design at `8ea764174ea80c7715c73c9bf918a39980307b03` now selects a [provider-bound standard ACP profile](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/interface-design.html>) alongside the existing Router-aware multiplexed profile. The bound profile selects one endpoint and the existing private-local owner identity; it does not constitute remote authentication. This supersedes this note's older statement that Router's initial ingress profile was unselected. It does not choose the AgentStudio Gateway–Host network admission contract.

The current [Router Requirements](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/requirements.md>) record the November 4 owner direction for an [ordinary MCP control facade](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/mcp-facade.html>). MCP tools call existing operation/session owners; an ACP-message tunnel is excluded. The first facade scope is text/session lifecycle, with richer media and other control mappings explicitly outside its first claim. An ACP client's requested MCP tool-server setup is a separate input from those incoming MCP control tools.

The [current first facade plan](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/plans/2026-11-05-mcp-facade-proof-boundaries.html>) records a one-PR, ready-unmerged delivery context owned by the Router effort. It sequences operator control, lasting controlled lifecycle proof, provider-specific actual-provider/original-CLI proof, then PR review. The later bound listener is not an inherent prerequisite to that first facade. M1 below remains inspectable historical planning; its plan-only terminal is not the current whole-Router delivery context. This does not transfer implementation, merge or production authority to the daemon effort.

The inspected design worktree has no committed crates/scripts/Cargo difference from its recorded `82a0d53bb` product base. The newer plan names separate implementation/source applicability and narrower F1/F2 evidence; neither that empty design-tree diff nor this research establishes the current implementation state in another worktree or installed service. No product build, provider run or fresh review of the entire Router design was performed here.

For AgentStudio, the separate [Host-upgrade continuity qualification](2026-11-01-system-boundaries/continuity-qualification.md), [iOS binding-safety gap](../increments/00-qualification/bridge-gateway-transport/native-binding-safety.md), capability migration and whole-system Verification Design remain open. Reusing Router control contracts cannot close those obligations by itself.

## Historical November 2 baseline

The owner asked whether provider injection is reusable across CLI, MCP and ACP, whether those frontends duplicate execution, and how to sequence the work. The checked answer is to keep provider variation separate from frontend variation, using the existing execution owners and typed contracts rather than adding a universal command framework.

### Owning design and authority

The ACP Lead owns the [Router shared-control design](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/index.html>) and [delivery proposal](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/delivery-plan.html>). Snapshot personally checked through `8781acc0e46affa07798c4bbc52097a14940cfc9`, including its unchanged completed M1 plan and recorded M2 steering gap; the underlying product sources inspected for this work were unchanged across the corresponding documentation refinements. Publication, merge and implementation approval were not established.

The existing Advisor supplied a separate source countercheck; its ongoing role continues after that bounded handback. No design authorship transferred between Leads. Governing Router changes remain with the ACP Lead; this note records what the daemon effort can learn and must still qualify.

### What is reusable

| Boundary | Responsibility | What stays outside it |
| --- | --- | --- |
| Provider behavior | Pure preparation and interpretation of the provider's dialect | Codex native DTOs, MCP schemas and frontend-selection flags |
| Host operation/session owners | Actual admitted execution, resource identities, custody, authority checks and observations | Another executor for each frontend |
| Protocol adapters | Their own request meaning, result timing, representation and intentional exposure | Independent provider/session truth |

Existing native/reverse-ACP session ports and MCP conversation-operation ports converge on the same external-provider supervisor/actors. They are not identical public APIs. Native input can carry typed content and explicit selected skills; the current MCP prompt conversion is text-oriented but carries stronger caller operation/recovery fields. Neither should become a lossy universal funnel for the other.

This conclusion concerns existing Router-owned external ACP-provider sessions. Native Codex retains its own existing backend and preservation controls. Reuse does not require replacing every backend with one global executor or importing the entire Router Host into a Gateway.

### The same execution has different protocol observations

| Frontend | Actual result boundary |
| --- | --- |
| Codex native prompt | Correlated turn start, not completion |
| MCP prompt | Existing/admitted operation snapshot; inspect actual state/settlement |
| Standard incoming ACP prompt | Matching turn end and update-ordering barrier before stop reason |

Keep connection request ID, admitted input ID, provider turn ID and durable operation ID distinct. Dropping an observer or losing a reply does not itself terminate the operation, prove non-submission or authorize replay.

### Selected Router design refinements, not implemented behavior

The Router proposal retains existing split prompt interfaces for its first three-entrypoint baseline. It selects actor-owned exact cancellation effects and explicitly changed idle/tracked/untracked inspection, with missing/unloaded distinct from known idle. The native adapter separately owns deferred settlement/terminal replies using its existing connection tasks; the command worker retains ordered admission. These are proposed structural changes requiring actual qualification.

The source walk corrected two misleading shortcuts:

- Host broker cleanup is requester/session-wide, but the current Supervisor records live cancellation as effect Unknown and refuses new same-scope prompt admission while it remains unresolved. A suspected successor-cleanup race was not established through the checked Host paths. Proof must separately exercise that admission fence and the lower runtime's actor-owned interval with the real Host interaction port/broker.
- At native pin `360319d8`, both normal completion and abort release pending interrupt responses. The CLI can also issue a second target request after recognized mismatch text. An interrupt response is not evidence that cancellation caused the ending, and one exact request differs from a whole interactive Stop action.

Callback guards drop after response enqueue, not after proving provider receipt. Source supports independent callback progress while the session actor waits, but no new runtime/deadlock or actual-provider pass was observed. No new broker migration, cleanup latch, universal trait, executor or transport was selected.

### Capabilities and incoming ACP

Capabilities have different suppliers: provider media/title support, Host queue/question routing, and frontend bookkeeping. Derive exposure from each operation's supplier/prerequisites, representation and actual admission. A flat intersection across every provider would unnecessarily remove provider-specific features; a capability offer does not grant permission.

In the November 2 product snapshot, the incoming ACP listener already had provider routes. Some standard methods and Router extensions have handlers; schema membership alone does not prove exposure or compatibility. Its initialization still advertises a fixed global media set before later provider selection. At that snapshot, the first broader-control negotiation contract remained open: provider-targeted connections versus qualified per-target negotiation on a multi-provider connection. No owner choice is inferred, and existing multi-route behavior remains authoritative meanwhile.

### Implications for AgentStudio

- Reuse actual operation/session owners and qualified client interfaces. Keep Swift/native presentation and wire adaptation outside provider behavior.
- A Gateway can remain a client to these owners; it need not embed provider process/storage packages merely to show/control sessions.
- Preserve admitted operation and rich-input meaning at the Host/Gateway boundary. Transport choice does not determine session lifetime or outcome semantics.
- Do not import the CLI's default-save no-op, mismatch retry or response deadline as universal daemon policy.
- This work does not qualify active-turn continuity across a real Studio Host upgrade. The earlier [native caller-loss experiment](2026-11-01-system-boundaries/native-continuity-results.md) retains its separate scope and limits.
- Durable tasks, board acceptance, peer mail, Git/worktrees, ZMX terminal identity and database replication remain separately owned capabilities. No existing migration checkbox is completed by this update.

### Sequence and evidence still owed

The Router proposal separates bounded CLI repairs from broader incoming ACP exposure. Its first visible repair is default-save compatibility; input/history and commands/callbacks follow their actual dependencies. Existing shared-prompt qualification belongs before integrated readiness; broader ACP design can proceed after the boundary milestone without waiting for every undated CLI information issue.

At the November 2 checkpoint, the [bounded M1 implementation plan](</Users/shravansunder/code/projects/codex-router.feat-acp-cli-actions/docs/specs/2026-11-02-acp-shared-control/plans/2026-11-02-m1-default-save.html>) was delivered with a scoped ready planning result. Its sequence is narrow native receipt handling and lasting client-proof apparatus, then qualification on both real providers. It requires the regular success-only persistence confirmation, an actual model/effort change with same-session native/provider readback, zero additional calls or writes from the save, and whole-run error observation. It is model-selection proof only: successful inference after selection remains unqualified. The requested delivery terminal was plan-only; neither implementation nor a PR/merge is authorized by that result.

Actual provider/client/Host-broker qualification, the remaining Router compatibility/information/startup contracts, broader planning admission and the future full-control negotiation contract remain open. The daemon must additionally qualify its own platform/dependency closure, physical execution custody, transport adapters and client integration. Source review is not any of those runtime proofs.

The ACP Lead independently counterchecked R7 steering and confirmed a source-level qualifier loss: `expected_turn_id` is checked against a hub snapshot before delivery awaits, while the runtime/actor command carries only session/input/content. The route lock does not serialize MCP admission, and steering creates no cancellation-style Supervisor operation fence. The incoming ACP adapter also captures a current turn into the same typed command, so this is a shared-boundary concern rather than only native presentation.

M2 now explicitly requires a targeted realization and outcome contract before steering integration. No new public target schema or outcome mapping has been selected. Its planned controlled proof holds the original A steer after the successful snapshot check, waits for A's terminal event **and durable operation settlement**, starts B through the real Supervisor, then releases the steer and observes actual provider/input effects. A still-Unknown operation could otherwise block B and mask the gap. The native client's separate retry/new-turn policy remains distinct. This is source-confirmed condition loss and a planned proof, not a reproduced runtime race; M1's plan is unchanged.

For the daemon design, the lesson is that shared typed interfaces must preserve each caller's targeting conditions through to the effect owner. A checked snapshot or a returned requested ID is insufficient evidence that an exact request acted on the right execution.

Detailed correspondence, bounded proposals, source counterchecks and their dispositions are in the current work trace and `tmp/spec-workflows/2026-11-02-codex-router-acp-shared-control/`; process records are not governing design.
