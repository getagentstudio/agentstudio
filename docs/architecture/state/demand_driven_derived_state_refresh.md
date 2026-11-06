# Demand-Driven Derived-State Refresh

> **Owns:** the generic vocabulary and mechanism-selection rule for expensive
> derived facts driven by product demand.
> **Does not own:** transport, workspace data ownership, or any concrete
> product contract. Those remain in their owning documents.

## Selection Rule

Classify the input before choosing a contraction or scheduling mechanism.
Do not begin by choosing debounce, throttle, polling, or a queue. Those are
mechanisms, not workload classifications, and each can silently discard an
ordering, scope, eligibility, or currentness obligation.

| Input class | Obligation to preserve | Fitting mechanisms |
| --- | --- | --- |
| Ordered fact | Every admitted transition and its order matter | Ordered delivery; bounded backpressure; no latest-value replacement |
| Latest-state projection | Only the newest complete state matters | Distinct-until-changed; latest-value coalescing; generation validation |
| Burst of samples | Individual samples may contract, but required statistics must survive | Fixed-key coalescing; bounded sufficient-statistics aggregation; explicit drain admission |
| Expensive refresh | Work is useful only for current consumer demand and scope | Demand admission; per-key single-flight; one latest pending invalidation; stale-result validation |
| Future eligibility deadline | Work becomes useful at a known future time | One reschedulable next-deadline task derived from policy; no fleet-wide periodic polling |

Compose only the mechanisms justified by the classifications present. A lane
may have more than one classification: Git refresh is an expensive refresh
whose affected paths form a scope-preserving latest-state projection, while
its freshness and recovery policy introduce future eligibility deadlines.

### Filter, Accumulate, Drop

Once the input is classified, three contracts decide what an intake may
discard. What it must keep comes from the classification, never from the
mechanism.

| Contract | Rule | Failure it prevents |
| --- | --- | --- |
| Filter | Decide relevance at the source, before any bounded buffer and before any debounce, against every event, using one rule owner. A stale view of that rule's inputs must err toward relevant. | Filtering after a bounded buffer lets irrelevant volume evict relevant events. Filtering after a debounce sees only the surviving event, so a relevant event in the middle of a burst is lost. Two copies of the rule drift apart. |
| Accumulate what the class keeps | Ordered facts keep every admitted transition in order, with bounded backpressure; they are never folded. Bursts of samples keep their declared statistics. Latest-state projections keep only the newest complete state. Expensive refresh keeps one bounded pending record per owned key (an open interval, a pending invalidation, a retry) with the union of scope it must serve, counted as logical debt until a covering result closes it. | Folding an ordered history into a refresh. An unbounded trigger queue. A latest-value replacement that forgets earlier scope. A "settled" or idle claim made while work is still owed. |
| Drop | Discard only what the filter proved irrelevant, what an equality gate proved equal, or, for a latest-state projection only, a value or result superseded by newer state (rejected by generation validation). Coverage loss (dropped, overflowed or wrapped events) is never discarded; it becomes a recovery obligation. Cancellation is reported as cancellation, never as suppression (see [R-INV Gate Kinds](#r-inv-gate-kinds)). | Silently losing the one change that mattered when the source or the buffer lost detail. |

These contracts compose with the mechanisms above. Debounce and maximum-wait
pacing are deadline policies for *when* accumulated refresh work becomes
eligible; they never decide *whether* an event is relevant. The concrete
FSEvents instance is
[Workspace Data Architecture — Watched-Folder Intake: Filter And Pacing](workspace_data_architecture.md#watched-folder-intake-filter-and-pacing).

## The Nine-Stage Loop

```text
observe
  -> project
  -> distinct-until-changed
  -> latest-value coalescing
  -> admission control
  -> single-flight execute
  -> stale-result validation
  -> fact publication
  -> materialized read model
```

The stages are responsibilities, not a requirement for nine types or nine
actor hops. A lane may prove that a stage is an identity operation. It must not
silently fuse stages when doing so hides what was suppressed, admitted,
superseded, published, or materialized.

## Vocabulary And Repository Instances

| Term | Meaning | Repository instance and owner |
| --- | --- | --- |
| Observe | Read the smallest authoritative inputs that can change demand or source facts | PR-fact demand observation is owned by the [Repository-Branch PR Facts Program Design — Demand and Bounded Refresh Flow](../../specs/2026-08-10-repo-branch-pr-facts/program-design.md#demand-and-bounded-refresh-flow). |
| Project | Convert source inputs into the exact identity and scope used by later stages | Pane and sidebar demand becomes repository/branch scope in the [PR-facts program design](../../specs/2026-08-10-repo-branch-pr-facts/program-design.md#demand-and-bounded-refresh-flow). |
| Source relevance filter | Discard events that cannot change the owned outcome before they enter a bounded buffer, keeping every coverage-loss signal | Watched-folder FSEvents drop ordinary file and directory churn inside known checkouts at the stream callback, while Git topology changes and coverage loss pass; see [Workspace Data Architecture — Watched-Folder Intake: Filter And Pacing](workspace_data_architecture.md#watched-folder-intake-filter-and-pacing). |
| Distinct-until-changed | Suppress work only when the owning gate can prove the required equality contract | Terminal title, CWD, and activity use terminal publication state; see [Pane Runtime EventBus Design — Admission And Hop Shape](../runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape). |
| Latest-value coalescing with scope preservation | Replace obsolete ordering context while retaining the union of affected scope required by the newest work | Git pending work unions affected paths across pending and retry debt; see [Workspace Data Architecture — GitWorkingDirectoryProjector](workspace_data_architecture.md#gitworkingdirectoryprojector). Coalescing must never drop an affected path merely because a newer trigger arrived. |
| Admission control | Decide whether work is useful now, for this identity and scope, before crossing the expensive owner boundary | Git refresh is demand-gated, and Repo Explorer admits only captured rendered topology slots; see [Workspace Data Architecture — GitWorkingDirectoryProjector](workspace_data_architecture.md#gitworkingdirectoryprojector) and [Sidebar Data Flow](workspace_data_architecture.md#sidebar-data-flow). |
| Single-flight | Permit at most one execution per owned key while retaining bounded follow-up intent | `ForgeActor` owns one active provider request per repository; see the [PR-facts bounded refresh flow](../../specs/2026-08-10-repo-branch-pr-facts/program-design.md#demand-and-bounded-refresh-flow). |
| Pending invalidation | A bounded record that current work became incomplete or obsolete and must be reconsidered when admission next permits it | The Git accumulator preserves affected scope while waiting for demand and re-arms from an eligible event; see [Workspace Data Architecture — GitWorkingDirectoryProjector](workspace_data_architecture.md#gitworkingdirectoryprojector). It is not an unbounded trigger queue. |
| Deadline scheduling | Schedule the earliest known eligibility time, then recompute it whenever policy inputs change | Git adaptive cadence and recovery deadlines are derived from `AppPolicies`; see [Workspace Data Architecture — GitWorkingDirectoryProjector](workspace_data_architecture.md#gitworkingdirectoryprojector). The PR-facts instance uses one next-deadline task; see its [program design](../../specs/2026-08-10-repo-branch-pr-facts/program-design.md#demand-and-bounded-refresh-flow). |
| Generation validation | Before publication, prove that the result still belongs to the latest identity, scope, and requested generation | Publication acknowledgement racing and scoped supersession reject stale derived work; the shipped keyed instance is described in [Workspace Data Architecture — Sidebar Data Flow](workspace_data_architecture.md#sidebar-data-flow). PR facts additionally validate captured origin, generation, and live branch membership. |
| Fact publication | Publish a changed, current domain fact to declared consumers; do not publish raw work intent as a fact | `EventBus` fact-interest matching limits delivery to declared topics; see [Pane Runtime EventBus Design — Current shipped behavior](../runtime/pane_runtime_eventbus_design.md#current-shipped-behavior). |
| Materialized read model | Bind the validated result into a keyed observable projection whose unaffected keys retain identity and revision | Repo Explorer uses `EagerDerivedAtomFamily`; see [Workspace Data Architecture — Sidebar Data Flow](workspace_data_architecture.md#sidebar-data-flow). |
| Concrete end-to-end instance | One implementation exercising the loop without redefining it | [Repository-Branch Pull Request Facts](../../specs/2026-08-10-repo-branch-pr-facts/requirements.md) observes visible demand, admits repository refreshes, validates current origin/generation/scope, publishes repository facts, and materializes keyed toolbar/sidebar reads. |

## Per-Stage Outcome Telemetry

Every implemented stage emits its outcome under bounded dimensions. A stage
without an observable outcome cannot support an enforceable gate or attribute
a regression to contraction, scheduling, execution, publication, or binding.

Required outcome families are selected to fit the lane, and include:

- observed/projected counts and bounded scope size;
- equal or suppressed counts at equality gates;
- admitted, deferred, rejected, and capacity-limited counts at admission;
- replaced or coalesced counts, plus retained-scope size, at coalescing;
- started, completed, failed, cancelled, and superseded counts at execution;
- stale-origin, stale-generation, or stale-scope rejection counts before publication;
- published, content-equal, and invalidated counts at fact publication;
- materialized, equal, superseded, and cancelled outcomes at keyed binding;
- waste ratios derived from counts with an explicit numerator and denominator.

Dimensions must be bounded policy or stage vocabularies. Raw paths, repository
names, branch names, UUIDs, prompts, payloads, and errors are not dimensions.
Cancellation is reported as cancellation. It is never counted as equality or
suppression merely because cancelled work did not publish.

## R-INV Gate Kinds

Distinct-until-changed has two different proof contracts:

| Gate kind | Required proof | Invalid shortcut |
| --- | --- | --- |
| Suppression gate | The sequence-end published state equals the ungated reference sequence | Treating cancelled, timed-out, or unobserved work as equal |
| Deferral gate | State equals the ungated reference at the first demanded checkpoint | Proving only eventual convergence after the checkpoint |

A suppression gate may remove proven-equal work. A deferral gate postpones
work until demand but must still meet the first demanded checkpoint. If a lane
cannot prove equality, it must retain pending invalidation or execute the work;
cancellation never converts uncertainty into suppression.

## Drift Discipline

This document owns the vocabulary above and the classify-first selection rule.
Owning architecture and specification documents own each instance's behavior,
identity, currentness, failure, and proof semantics. They cite this pattern
when selecting mechanisms; this document cites their sections as examples and
does not restate their contracts.

When an instance needs a new mechanism:

1. classify the input and name the obligation the mechanism preserves;
2. select only mechanisms licensed by that classification;
3. define per-stage bounded outcomes and the relevant suppression or deferral gate;
4. update the owning document's semantics and leave this vocabulary generic.

If a concrete owner and this document disagree about instance behavior, the
concrete owner drives that instance and this document must be corrected only
where its generic vocabulary or selection rule is wrong.

## Owning Documents

- Transport and subscriber fact-interest: [Pane Runtime EventBus Design](../runtime/pane_runtime_eventbus_design.md)
- Workspace/Git/Forge ownership and Repo Explorer materialization: [Workspace Data Architecture](workspace_data_architecture.md)
- Concrete repository-branch PR-facts contract: [Requirements](../../specs/2026-08-10-repo-branch-pr-facts/requirements.md), [Specification](../../specs/2026-08-10-repo-branch-pr-facts/specification.md), and [Program Design](../../specs/2026-08-10-repo-branch-pr-facts/program-design.md)
