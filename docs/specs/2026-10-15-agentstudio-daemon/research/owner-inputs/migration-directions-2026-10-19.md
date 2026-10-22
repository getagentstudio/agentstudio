# Owner directions: incremental Rust migration

These are direct owner messages in the Lead conversation on2026-10-19. They clarify the requested delivery map and development constraints. They authorize design/migration planning; they do not select a final transport, target schema, first release scope or permission to execute product changes in this design run.

## Both repositories and the path to the result

> agentstudio and agentstudio-git have ltos of features that needs to be done with a strangler patter and we start movign things into the new rust system and deamon and fiure out the plan and psec sits not jsut design ahow we gonna accomplishw aht we neeed?

## Full map, detailed near term

> We need to map everything out so that we know the sequence of getting there and align the path. ... it doesn't have to be super detailed. Only the near-term map has to be super detailed, but a high-level map ... where each feature lives ... observations and events ... commands are mapped out

## Independent comparison, hierarchy and permitted redesign

> Get the advisors help to validate everything independently of yourself, so that both of you reach the same conclusions and check each other's work. ... all the features are covered somewhere and nothing can be missed. We have a checklist. ... checklists are supposed to be trees, not one giant block of text. ... opportunity to design things better as long as the ... contracts towards the client remains the same ... components and boundaries are super important

The direct instruction permits internal redesign while preserving the selected client-facing outcomes/contracts. An inventory row or checked document is not a claim that a feature is ported. New product behavior, authority, retention or public-contract changes still need their own authorization.

## Fleet and deployment scope

> The Fleet idea is I think they're orthogonal ... it's not a bot. ... deployment is ... like a workspace, or correlates to what's in the workspace.

The Lead asked whether one Host deployment belongs to one workspace or may serve several. The owner answered **“Leave that relationship open for now.”** The later message repeats that it can be figured out later; focus on remote operation, boundaries, cohesive subsystems/crates/dependencies/separation of concerns, using Codex Router, also known as agent-collaboration, as the Rust standards reference. Neither cardinality is selected. No Fleet, bot-agent-server or machine provisioning implementation becomes a dependency of this migration map.
