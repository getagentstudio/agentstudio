# What to retain from the old domain designs and increments

**No deletion is justified by this inventory.** The new direction is preliminary and does not replace the old feature contracts, data catalog, migration map or qualification evidence. Some mechanisms and source baselines need revision; that is different from removing their obligations or historical evidence.

Scope: `docs/specs/2026-10-15-agentstudio-daemon/designs/` and `increments/`. All filenames were enumerated. The design index, eleven design briefs and nine increment/index briefs were read; not every detailed document was rereviewed for current semantics. Detailed terminal/mobile sources were read separately in the linked research notes. This is brief-level retention triage, not whole-design acceptance or a complete semantic obsolescence audit.

## Inventory

| Selected content | Count |
| --- | ---: |
| Domain designs and their navigation/assets | 185 files |
| Delivery increments and their navigation | 61 files |
| Markdown files across both | 102 |
| HTML files across both | 123 |
| Other assets across both | 21 |
| HTML files with a same-stem Markdown file | 102 |
| HTML files without that pairing | 21 |

The complete old spec tree currently contains 596 files; the selected subtrees contain 246 of them. Pairing filenames does not prove an HTML file is disposable or identify its renderer binding. The 21 unpaired HTML files include navigation pages; they must not be treated as redundant readers by count alone.

The [machine-readable inventory](../../../../tmp/practices-research/2026-11-14-rex-direction/old-doc-inventory.json) includes every selected path and static inbound references from 1,162 scanned Markdown/HTML/root documentation files. It found 3,796 matching link occurrences and at least one static inbound reference for 245 selected files. These are mechanical counts, not distinct product dependencies or a proof that dynamic/external consumers are absent.

## Foundations: keep the detailed meaning while the new direction settles

- [DS01 service contracts](../../2026-10-15-agentstudio-daemon/designs/01-service-contracts/README.md), **13 files**: Host-qualified targeting, real operation outcomes, IPC/CLI exposure and producer/consumer compatibility. Rex and new connectivity candidates increase the need for these contracts. Revise selected transport/hosting clauses only after their decisions; retain the operation inventory and refusal semantics.
- [DS02 data ownership and replication](../../2026-10-15-agentstudio-daemon/designs/02-data-ownership-replication/README.md), **32 files**: table/column inventory, transaction closure, source-qualified copies, prepared views and shared-state meaning. A direction-level fleet diagram does not replace this detail. The old 86-table catalog is a historical source inventory, not a claim that the current app has exactly that live schema.
- [DS03 authority and leases](../../2026-10-15-agentstudio-daemon/designs/03-authority-control-plane/README.md), **5 files**: lease validity, caller authority, credential revocation and effect-time gates. O9 changes are unresolved; keep the competing obligations visible until their owner resolves them. Terminal control and database write leases remain different concepts.

## Execution and resources: the backend choice replaces none of these feature contracts

- [DS04 terminal runtime](../../2026-10-15-agentstudio-daemon/designs/04-terminal-runtime/README.md), **20 files**: execution/attachment distinction, no-view facts, input uncertainty, restoration and control. Keep source observations/results with their original versions; the new Rex adapter question is additional qualification.
- [DS05 Git/discovery](../../2026-10-15-agentstudio-daemon/designs/05-git-discovery/README.md), **9 files**: operation classification, Git/ref/index effects, watchers and currentness. Neither Rex nor Central replaces the complete Git surface.
- [DS06 worktree fork](../../2026-10-15-agentstudio-daemon/designs/06-worktree-fork/README.md), **9 files**: Mac/Linux counterpart, filesystem/metadata profile, joined cancellation and residue. Preserve the owner-required parity obligation and the exact limits of any leaf experiment.
- [DS07 agents/context](../../2026-10-15-agentstudio-daemon/designs/07-agents-context/README.md), **16 files**: provider/conversation/binding identities, Host-local admission, retained notices/asks and atomic intake. Reconcile provider execution custody with Router; do not erase these feature behaviors merely by selecting an execution owner.
- [DS08 files/reviews/output](../../2026-10-15-agentstudio-daemon/designs/08-files-review-output/README.md), **14 files**: revision-bound content, annotation/edit custody, immutable output membership and actual destination effects. A Rex action opening a review does not replace the review contract or its native/output failure boundaries.

## Clients and the migration path

- [DS09 Gateway/CLI](../../2026-10-15-agentstudio-daemon/designs/09-gateway-cli/README.md), **13 files**: several Hosts/Gateways, explicit targeting, machine-local worktree CLI versus frontend entry, source data and prepared views. New network reachability is one input, not a replacement for the route distinctions.
- [DS10 native clients](../../2026-10-15-agentstudio-daemon/designs/10-swift-client/README.md), **18 files**: the command inventory, source/currentness, thin native publication and addressed native effects. A proposed socket change does not make the native catalog or platform consent irrelevant.
- [DS11 operations/integration](../../2026-10-15-agentstudio-daemon/designs/11-operations-integration/README.md), **32 files**: hierarchical migration checklist, feature/operation crosswalk, near-term slice, crate/DAG/unsafe constraints and integrated proof. Retain as the feature-coverage map until a replacement carries every still-authorized obligation. Source baseline and workflow references may require upkeep, not deletion.
- The remaining **4 design files/assets** are design-root navigation and its diagram. Any retirement must preserve working routes into retained documents.

## Increment tree: retain the usable outcomes; revise their prerequisites deliberately

- **I0 qualification — 23 files.** Includes focused ZMX adoption and Bridge transport/binding Program/Verification Designs. Preserve evidence and safety failures even if an implementation candidate is later superseded. An unexecuted new experiment is not replacement evidence.
- **I1 remote terminal — 5 files.** Revisit its backend-specific integration after the common terminal contract is selected; keep the initial usable remote-workflow outcome.
- **I2 agents/context — 5 files.** Keep no-view/no-Gateway operation and retained input/fact obligations; reconcile their actual provider owner.
- **I3 repository reads — 5 files.** Keep the remote sidebar/Git/content outcome and currentness boundaries.
- **I4 Git/worktrees — 5 files.** Keep complete selected mutations and Linux fork parity.
- **I5 reviews/output — 5 files.** Keep real review-to-agent and declared native destination effects.
- **I6 replication/sharing — 5 files.** Keep its data classes, units and selected sharing obligations visible while O9 is resolved; do not assume a new Central diagram transfers them elsewhere.
- **I7 clients/operation — 5 files.** Revisit platform/network mechanisms without removing required phone/CLI/MCP/concurrent-client outcomes.
- **3 increment-root pages** provide sequencing/navigation; retiring them requires replacement routes into the retained outcomes.

The [increment index](../../2026-10-15-agentstudio-daemon/increments/README.md) explicitly describes proposed scopes, not implementation plans or delivered features. The new direction can simplify the sequence without treating an unchecked migration checklist as completed work.

## One orphan lead, not a deletion decision

`designs/01-service-contracts/assets/communication-1.svg` had no inbound link recognized by this bounded static scanner. That makes it a candidate for checking component-generated/dynamic navigation and duplicate visual meaning. It does not establish absence of a consumer, a superseding visual, or permission to remove it. No file was deleted.

## Retirement gate

For any later candidate, name the actual owner decision or completed replacement, account for current consumers and source/reader/navigation assets together, and preserve unique owner quotations and experimental evidence. First correct conflicting obligations in the new direction; then perform bounded document upkeep. Neither age nor an agent's preference establishes supersession.
