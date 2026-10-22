# I3 — Remote repository discovery, Git reads and bounded content

The usable outcome is a remote-backed AgentStudio repository sidebar and selected status/diff/review reads with honest Host/source currentness. Basis: U4/U6/U9/U11/U13/U18; K1/K3/K9/K11/K13 and R2/R4/R11/R15/R16.

| Slice | Observable result | Boundary to preserve |
| --- | --- | --- |
| Exact repository candidate / inventory | Validated repository/worktree evidence or explicit non-repository/failed access | No ancestor fallback for exact lookup; unreadable is not empty success |
| Status / tracked paths / ignore | Declared scoped facts and optional exact detail | Scoped empty is not clean full worktree; config/index changes and conflict stages matter |
| Branch/use/graph/review targets | Resolved objects plus mutable-name/coverage/bound distinctions | A branch name is not immutable revision; bounded search/truncation is not proof of completeness |
| Diff/tree/content | Typed binary/missing/truncated/too-large/cancelled/failed results and finite content | Correct transport bytes are not source currentness or worker/native application |
| Observation/refresh | Host source, coverage and continuity with client demand as an input | No Swift-only sole fact owner; no-demand result does not describe every repository/Forge fact |

Current app entry is filesystem/Git pipeline and RepoScanner → pinned Git package → native/current-source observations → detached derived sidebar/view readers. Target Host owns source observation and Git reads; Gateway/client adapters publish compact prepared observations to the existing sidebar/Bridge consumers. The existing owning package's semantics remain the reference; the Rust/Linux library realization cannot be inferred from an SDK method name.

Select public read subset, path/filename domain, identity after replacement, exact observation/watch/overflow/restart contract, content kinds/bounds and supported source/platform profiles. Do not interpret a remote path as a local Mac URL. Replica freshness and permission are separate from connection health.

Prove actual Mac/Linux Git/filesystem fixtures, equal paths on distinct Hosts, stale/raced candidates, missing/partial/lost coverage, source mutation during reads, finite content construction/delivery/currentness and real supported sidebar/viewer publication. This read increment does not claim the mutation/fork contract or all SDK operations.
