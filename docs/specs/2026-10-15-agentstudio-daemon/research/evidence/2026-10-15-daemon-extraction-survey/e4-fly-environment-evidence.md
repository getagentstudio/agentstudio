# E4 Fly environment evidence

Date: 2026-10-15. Mode: source-only design input. Repository baseline: `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462` (`feat/daemon`). Governing scope: [primary experiments, E4](../../../experiments/primary-experiments.md#e4--safe-linux-capability-and-parity), read in full including its execution boundaries.

Question: which Fly defaults and documented storage facilities constrain a disposable Linux clone/containment/metadata feasibility probe, and which facts remain guest observations?

No authenticated Fly call, provisioning, guest execution, tests, builds, prototype, credential inspection, product edit, board action or helper was performed. The sole requested evidence file was written. This is not a probe recipe, execution authorization, supported-filesystem decision or Linux parity verdict.

## Disposition

**Fly is a candidate environment, not a demonstrated clone-capable Linux profile.** The inspected CLI accepts raw volumes and defaults ordinary volume creation to `ext4`. Neither fact establishes the future guest kernel's filesystem drivers, mount/loop privileges, exact mount stack, reflink feature flags, metadata behavior or `FICLONE` outcome. A rootfs-only refusal can establish only the tested refusal boundary under its recorded profile; it leaves the positive-capability and cross-device arms open.

**`--shell` is not whole-environment disposal.** The installed help and pinned source retain/reuse an interactive-shell app. Machine destruction can leave a volume unattached. Implicit app reuse is not proof that the app is fixture-owned or safe to delete.

## Six decisive primary sources

| ID | Source and exact section | Receipt and limit |
| --- | --- | --- |
| S1 | Installed `flyctl machine run --help`, exit `0` | Read 2026-10-15. Executable resolves to `/opt/homebrew/Cellar/flyctl/0.4.115/bin/flyctl`; SHA-256 `a6f0e6749986831f5cc2365bad7747a930e601caf3926ef538e223877b9446c5`. Help is observed; a hosted API result is not. Relevant flags: `--shell`, `--rm`, `--restart`, `--autostart`, `--autostop`, `--rootfs-persist`, `--rootfs-size`, `--volume`, `--user`. |
| S2 | [flyctl `run.go`, pinned v0.4.115](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/machine/run.go) | Tag resolves to commit `a1cf49a52b36fba66a2bf0907617bd5aadb8a727`. Flags: 125–164, 192–199, 260–274. AutoDestroy/app selection: 330–390. SSH cleanup: 474–505. App reuse: 536–580. Rootfs fields: 702–729. Restart: 834–870. Service autostart/autostop assignment: 891–922. Source configuration is not hosted execution. |
| S3 | [flyctl `volumes/create.go`, same pin](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/volumes/create.go#L36-L80) | Snapshot/encryption defaults: 46–59. Hidden `fs-type` accepts `ext4` or `raw`, default `ext4`: 75–80 and 143–149. Request fields and optional scheduled-snapshot assignment: 157–176. No claim that raw storage is already formatted/mountable. |
| S4 | [Run a new Machine](https://docs.fly.io/machines/flyctl/fly-machine-run) — “Get a shell on a temporary Machine”, “Set Fly Proxy autostop/autostart”, “Stop or restart the machine on process exit”, “Destroy the Machine when it exits”, “Mount a Fly Volume” | Directly read the official markdown representation. Confirms retained shell app, restart distinction, service-only proxy behavior, and separate volume attachment. These public docs are live/unpinned and include wording drift identified below. |
| S5 | [Fly Volumes overview](https://docs.fly.io/volumes/overview) — introduction, “Volume considerations”, “Volume attachment”, “Volume snapshots” | Rootfs is described as ephemeral. Volumes are app-owned, local to one server/region, persistent, and one-to-one with Machines. Machine deletion can leave an unattached volume. Automatic daily snapshots/default retention are separate state. No rootfs clone-capability guarantee appears. |
| S6 | [Volumes API](https://docs.fly.io/machines/api/volumes-resource) — “Volume properties”, “Create a volume” body fields, “Delete a volume permanently”, “Get a list of snapshots for a volume” | `fstype` defaults to `ext4`; backups default enabled and retention defaults to five days. Volume deletion is a distinct irreversible API operation; snapshots have separate listing/state. This does not prove deletion behavior for every related resource. |

Primary HTTP retrieval was read-only. The standard `~/Documents/dev/open-source/flyctl` checkout was absent, so primary upstream files were read at the installed-version tag. A newer master SHA was discovered but is not the accepted CLI source pin.

## Storage facts and proof limits

| Surface | Supported source fact | Still requires guest observation |
| --- | --- | --- |
| Rootfs | Ephemeral default storage; persistence/size controls exist. `--rootfs-size` help explicitly mentions an overlayfs. [S1, S2:159–164 and 702–729; S5 introduction] | Actual kernel release/configuration, filesystem types, mount layers/options, device identities, backing features, free space and clone behavior on the exact source/destination paths. Do not label every Fly rootfs `ext4` from the volume default. |
| Ordinary volume | Documented API/CLI filesystem default is `ext4`; volume belongs to one app and one Machine at a time. [S3:75–80; S5 “Volume considerations”; S6 create fields] | Actual formatted/mounted filesystem and feature set, user/capability context, metadata/ACL/xattr behavior and exact operation outcome. The default name does not settle capability. |
| Raw volume candidate | Pinned CLI validates and submits `fs-type=raw`. This is a candidate facility for separate scratch storage. [S3:143–167] | Whether the service accepts it for the selected allocation; how it is exposed/bootstrapped; guest driver and formatting-tool availability; mounting privilege; and a real clone success. No inspected source guarantees a particular Btrfs/XFS scratch configuration. |
| Cross-device arm | Rootfs and a volume are distinct documented storage roles; docs permit one mounted Fly Volume per Machine. [S4 “Mount a Fly Volume”; S5 “Volume considerations”] | Actual source/destination device and mount identities. Different directory names, or a rootfs/volume label, are not sufficient evidence of the intended cross-device boundary. Do not assume two simultaneously attached Fly Volumes. |

Creating a fixture-owned filesystem entirely inside a disposable guest or on a separately owned disposable disk would not itself require changing shared-host kernel settings. That is an isolation observation, not proof that the selected guest supports it or authorization to perform it. Root shell selection is available (`--user` defaults to `root`, S1/S2:260–269); it does not independently establish all kernel capabilities, loop devices, modules or mount permissions. No unsupported shared-infrastructure modification is needed or authorized by this report.

Installing a userspace formatting tool cannot supply a missing guest kernel filesystem driver. If the actual guest cannot realize a positive clone-capable scratch arm without a prohibited host change, that profile is insufficient for that arm; it is not evidence that Linux generally cannot preserve the Mac contract.

## Lifecycle, isolation and cleanup boundaries

| Topic | Verified behavior | Consequence for later execution |
| --- | --- | --- |
| Shell app | `--shell` implies interactive mode and removal; absent an app, source searches existing org apps for the `flyctl-interactive-shells-` prefix and reuses the first match, otherwise creates one. It retains the app. [S2:330–390, 536–580; S4 temporary shell] | Implicit shell mode is not a dedicated-app ownership guarantee. The Lead must establish exact app ownership before provisioning or cleanup. A reused app must not be treated as disposable. |
| Machine removal | `AutoDestroy` follows `--rm`; shell mode forces it. The shell path additionally calls Machine `Destroy` after `ssh.Console`. Earlier launch/start/SSH errors can return before that explicit call; it is not an unconditional deferred cleanup. Interactive default init uses `/bin/sleep inf` at S2:791–798. [S2:389–390, 474–505] | Successful shell exit is the documented ordinary path; abnormal failure still needs an independent resource receipt. No source-only statement that every error leaves zero residue. |
| Restart | Normal `machine run` defaults to `always`; `--rm` defaults restart to `no` when no explicit policy overrides it. The source says AutoDestroy depends on policy `no`. [S2:834–870; S4 process-exit/removal] | Process-exit restart is separate from proxy autostart. Do not assume an explicitly conflicting restart value is silently corrected. |
| Autostart/autostop | Help displays autostart `true`, autostop `off`; source writes these per-service fields only when the corresponding flag is specified. Guide says the flags operate only with Fly Proxy services; absent flags leave fields unset. [S2:125–134, 891–922; S4 proxy section] | Help's parsed flag default is not a guarantee of effective proxy behavior. These mechanisms are not a general shell timeout or disk cleanup policy. |
| Rootfs/data | Removing the Machine differs from stopping it or selecting rootfs persistence. [S1; S2 rootfs fields; S4 removal; S5 introduction] | Record actual Machine terminal state and owned disk state; a stopped resource is not a destruction receipt. |
| Volume | Machine destruction may release attachment while retaining the volume; permanent volume deletion is separate. [S5 “Volume attachment”; S6 deletion] | `--rm` does not close the volume-cleanup boundary. Destroy only an independently identified fixture-owned volume when later authorized. |
| Snapshots/images/other resources | Snapshot creation/retention is separate and defaults can create retained data. No inspected source establishes that `--rm` deletes snapshots, images, build artifacts, app allocations or other app resources. [S3:46–54,170–171; S5 snapshots; S6 properties/snapshot endpoints] | Retention must be an explicit resource inventory/disposition, not an assumed side effect. No image/remote-builder cleanup behavior was proved here; no current pricing claim is made. |

## What a rootfs-only refusal means

If a later probe observes a clone request rejected on its recorded rootfs path, with actual operation/error and independent source/destination/post-state observations, that can establish truthful refusal for that profile and effect boundary. It does not establish clone support, byte copying, metadata preservation, rollback/cleanup, cross-device behavior, all Fly storage profiles, all Linux filesystems, or Linux feature parity. No such request was executed here.

Conversely, a positive byte result would still need independent identity/copy-versus-clone evidence and the admitted metadata/containment outcomes before it could close those E4 obligations. This report does not choose an oracle, fallback or filesystem support policy.

## Contradictions, nulls and coverage

- DeepWiki-first query: `superfly/flyctl` — “Bounded read-only check of Fly Machine run defaults for a disposable Linux filesystem feasibility experiment”, explicitly asking about shell/rm/app/volume/image cleanup, restart/autostart, rootfs and scratch privileges. It supplied owner paths but incorrectly repeated an app-deletion interpretation. S1/S2/S4 refute that interpretation: the shell app is retained.
- Help's `--rm` description uses restart-policy `never`; the accepted restart flag/source/API value is `no`. S2:836–838,858–860 and S4 settle the spelling. Do not turn the help prose into `--restart never`.
- S4 still mentions legacy `on-fail` in its option prose; installed help and pinned source accept `on-failure` (the source retains an older alias). This does not change the removal default.
- Source route: current E4 artifact and installed help first; DeepWiki before OSS code; then pinned upstream source and official Fly documents. Perplexity discovery queries: `site.fly.io/docs Machines root filesystem ext4 volume raw fs-type shell rm app retained` and `site.fly.io/docs rootfs overlayfs ext4 raw filesystem volume btrfs kernel`. Search snippets were discovery only.
- Null: expected local flyctl OSS checkout was absent. Primary fallback: pinned GitHub raw files.
- URL nulls: `https://fly.io/docs/machines/flyctl/fly-machine-run/index.md` and `https://fly.io/docs/machines/api/volumes-resource/index.md` returned 404. The current `https://docs.fly.io/... .md` routes succeeded; canonical source URLs are S4/S6.
- `flyctl version` exited `1` during local configuration-permission setup (`operation not permitted`); no credential inspection or retry was performed. Executable version identity instead comes from its resolved Homebrew `0.4.115` path plus SHA-256, and its matching source tag was independently resolved through the public GitHub API. This failure is not evidence of a Fly service outage or login state.
- Unsearched/not executed: authenticated account/app/Machine/volume state; current quotas/prices; actual guest kernel/mounts/capabilities; source/target clone operations; privilege changes; custom kernel installation; guest filesystem setup; image cleanup; snapshot deletion semantics. These are out of this source-only authorization.
- No independent helper countercheck was commissioned because this task forbids new agents. The Lead independently accepts the source anchors. No prior-memory fact is needed for these findings.

## Completion and return

Evidence file readback is the artifact check; no product proof is claimed. Source support for a candidate raw scratch disk is accepted; guaranteed clone-capable Fly guest storage and universal cleanup are unresolved/refuted as broad claims. Existing E4's requirement to record actual capabilities remains appropriate.

Return token: `program-design-gap` — the Lead's later probe must name an isolated guest/storage profile and exact resource ownership, observe its real capabilities, and separately account for Machine, app, volume and retained artifacts. This report selects none of those product policies and authorizes no execution.
