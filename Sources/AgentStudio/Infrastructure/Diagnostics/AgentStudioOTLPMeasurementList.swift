// Source inventory classified by the Lead, 2026-10-22 (handback 1).
// This list alone admits numeric measurements. Boolean values never measure.
// Flags, generation/revision/sequence identities, fingerprints and schema
// versions remain log fields; they do not become measurements.
// Exclusions decided by the Lead:
// - telemetry.value: mixed unit by code; split per code if a consumer needs it.
//   Splitting it is outside this change.
// - native_table_pilot.growth_percent: query-time ratio of listed durations.
// - native_table_pilot.warmup.count / measured.count: configured bookkeeping.
// - git.backoff_attempt.count: attempt ordinal, not an accumulated tally.
// - telemetry.{main,comm}_producer.high_watermark: sequence barriers.
// - demand.queue_depth / stale_drop.count and metadata_manifest totals: no
//   current emitter or ingress declaration; excluded even while old maps remain.
// input_revision.count, stale_generation.count and topology.index.count are
// tallies. pending_high_water_mark and hydration_unclassified.current are
// occupancies, not sequence identities.
// trace_queue statistics use process gauges; copies in log attributes never
// become per-event measurements.
// The Lead classified all 16 scrollback pass names as listed on 2026-10-23:
// pane/outcome tallies are counts; captured/committed byte totals are sizes.
// Generic Bridge entries name their ingress declaration; the recorder copies
// those numeric members in BridgePerformanceTraceRecorder.swift:103.

enum AgentStudioOTLPMeasurementList {
    static let names: Set<String> = performanceNames.union(bridgeNames)

    private static let performanceNames: Set<String> = [
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:273; duration
        "agentstudio.performance.apply_governor.awaited_ms",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:270; count
        "agentstudio.performance.apply_governor.batch.count",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:272; count
        "agentstudio.performance.apply_governor.carried_over.count",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:279; duration
        "agentstudio.performance.apply_governor.mainactor_held_ms",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:282; duration
        "agentstudio.performance.apply_governor.max_single_fact_ms",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:276; duration
        "agentstudio.performance.apply_governor.queue_wait_ms",
        // Sources/AgentStudio/App/Coordination/BackgroundFactApplyGovernor.swift:271; count
        "agentstudio.performance.apply_governor.superseded.count",
        // Sources/AgentStudio/Infrastructure/AtomLib/AtomPerformanceTelemetry.swift:157; count
        "agentstudio.performance.atom.accepted_change.count",
        // Sources/AgentStudio/Infrastructure/AtomLib/AtomPerformanceTelemetry.swift:163; occupancy
        "agentstudio.performance.atom.cached_key.count",
        // Sources/AgentStudio/Infrastructure/AtomLib/AtomPerformanceTelemetry.swift:166; count; tally, not ordinal
        "agentstudio.performance.atom.input_revision.count",
        // Sources/AgentStudio/Infrastructure/AtomLib/AtomPerformanceTelemetry.swift:178; count
        "agentstudio.performance.atom.shed_read.count",
        // Sources/AgentStudio/Infrastructure/AtomLib/AtomPerformanceTelemetry.swift:160; occupancy
        "agentstudio.performance.atom.slot.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:166; count
        "agentstudio.performance.commandbar.item.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:174; count
        "agentstudio.performance.commandbar.pane.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarPanelController+Search.swift:268; size
        "agentstudio.performance.commandbar.query_character.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:170; count
        "agentstudio.performance.commandbar.repo.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarPanelController+Search.swift:271; count
        "agentstudio.performance.commandbar.result.count",
        // Sources/AgentStudio/Core/Search/SearchService.swift:81; count
        "agentstudio.performance.commandbar.search.duplicate_item.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:171; count
        "agentstudio.performance.commandbar.worktree.count",
        // Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:167; count
        "agentstudio.performance.commandbar.worktree_row.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:515; count
        "agentstudio.performance.coordinator.active_pane_write.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:512; count
        "agentstudio.performance.coordinator.activity_write.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:133; count
        "agentstudio.performance.coordinator.derived_envelope.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:134; count
        "agentstudio.performance.coordinator.derived_input.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:521; duration
        "agentstudio.performance.coordinator.filesystem_source_elapsed_ms",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:135; duration
        "agentstudio.performance.coordinator.index_elapsed_ms",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:141; count; tally, not ordinal
        "agentstudio.performance.coordinator.input_revision.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:138; duration
        "agentstudio.performance.coordinator.mainactor_apply_elapsed_ms",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:144; count
        "agentstudio.performance.coordinator.pane.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:510; count
        "agentstudio.performance.coordinator.registered.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:518; count
        "agentstudio.performance.coordinator.sidebar_visible_write.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:145; count
        "agentstudio.performance.coordinator.skipped_unchanged_input.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:540; count
        "agentstudio.performance.coordinator.source_sync.admitted_worktree.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:537; count
        "agentstudio.performance.coordinator.source_sync.batch_count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:148; duration
        "agentstudio.performance.coordinator.total_elapsed_ms",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:511; count
        "agentstudio.performance.coordinator.unregistered.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:151; count
        "agentstudio.performance.coordinator.worktree.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:499; duration
        "agentstudio.performance.elapsed_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:708; count
        "agentstudio.performance.filesystem.affected_key_request.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:50; count
        "agentstudio.performance.filesystem.drain_task.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:706; count
        "agentstudio.performance.filesystem.full_reconciliation_request.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:209; count
        "agentstudio.performance.filesystem.ingress.local.accepted.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:210; count
        "agentstudio.performance.filesystem.ingress.local.accepted.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:211; count
        "agentstudio.performance.filesystem.ingress.local.dropped.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:212; count
        "agentstudio.performance.filesystem.ingress.local.dropped.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:213; count
        "agentstudio.performance.filesystem.ingress.local.terminated.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:214; count
        "agentstudio.performance.filesystem.ingress.local.terminated.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:113; count
        "agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:116; count
        "agentstudio.performance.filesystem.ingress.local_raw_callback.event.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:189; count
        "agentstudio.performance.filesystem.ingress.overflow.coarse_recovery.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:182; count
        "agentstudio.performance.filesystem.ingress.overflow.drain.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:183; count
        "agentstudio.performance.filesystem.ingress.overflow.recovery.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:186; count
        "agentstudio.performance.filesystem.ingress.overflow.retained_path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:164; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.active_recheck.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:179; size
        "agentstudio.performance.filesystem.ingress.shared_ancestor.byte_read.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:134; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.candidate.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:140; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.changed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:137; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.equal_resolved.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:161; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.fail_closed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:176; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.item_read.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:143; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.missing_baseline.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:149; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.policy_bound_exhausted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:155; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.raced.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:158; count; tally, not ordinal
        "agentstudio.performance.filesystem.ingress.shared_ancestor.stale_generation.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:170; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_item.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:167; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.unresolved_registration.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:152; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.unstable.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:146; count
        "agentstudio.performance.filesystem.ingress.shared_ancestor.unsupported.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:209; count
        "agentstudio.performance.filesystem.ingress.shared_exact.accepted.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:210; count
        "agentstudio.performance.filesystem.ingress.shared_exact.accepted.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:211; count
        "agentstudio.performance.filesystem.ingress.shared_exact.dropped.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:212; count
        "agentstudio.performance.filesystem.ingress.shared_exact.dropped.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:213; count
        "agentstudio.performance.filesystem.ingress.shared_exact.terminated.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:214; count
        "agentstudio.performance.filesystem.ingress.shared_exact.terminated.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:125; count
        "agentstudio.performance.filesystem.ingress.shared_exact_subscriber.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:131; count
        "agentstudio.performance.filesystem.ingress.shared_full_refresh_emission.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:119; count
        "agentstudio.performance.filesystem.ingress.shared_raw_callback.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:122; count
        "agentstudio.performance.filesystem.ingress.shared_raw_callback.event.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:209; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.accepted.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:210; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.accepted.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:211; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.dropped.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:212; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.dropped.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:213; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.terminated.batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:214; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty.terminated.path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventIngressPerformanceAccumulator.swift:128; count
        "agentstudio.performance.filesystem.ingress.shared_uncertainty_subscriber.count",
        // Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift:590; count
        "agentstudio.performance.filesystem.local_stream.logical_registration.count",
        // Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift:587; count
        "agentstudio.performance.filesystem.local_stream.physical.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:56; occupancy
        "agentstudio.performance.filesystem.logical_debt.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:49; count
        "agentstudio.performance.filesystem.pending_worktree.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:52; count
        "agentstudio.performance.filesystem.watched_folder.active.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:53; count
        "agentstudio.performance.filesystem.watched_folder.dirty_follow_up.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/FilesystemActor+LogicalDebt.swift:51; count
        "agentstudio.performance.filesystem.watched_folder.ready.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:419; count
        "agentstudio.performance.forge.admission.active_request_coalesced.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:413; count
        "agentstudio.performance.forge.admission.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:425; count
        "agentstudio.performance.forge.admission.backoff_deferred.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:421; count
        "agentstudio.performance.forge.admission.capacity_limited.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:423; count
        "agentstudio.performance.forge.admission.freshness_deferred.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:417; count
        "agentstudio.performance.forge.admission.missing_origin_rejected.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:415; count
        "agentstudio.performance.forge.admission.no_demand_rejected.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:467; count
        "agentstudio.performance.forge.deadline.cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:466; count
        "agentstudio.performance.forge.deadline.fired.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:464; count
        "agentstudio.performance.forge.deadline.rescheduled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:462; count
        "agentstudio.performance.forge.deadline.scheduled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:429; count
        "agentstudio.performance.forge.execution.automatic_without_demand_started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:444; count
        "agentstudio.performance.forge.execution.cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:441; count
        "agentstudio.performance.forge.execution.completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:443; count
        "agentstudio.performance.forge.execution.failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:427; count
        "agentstudio.performance.forge.execution.started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:446; count
        "agentstudio.performance.forge.execution.superseded.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:431; count
        "agentstudio.performance.forge.explicit.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:439; count
        "agentstudio.performance.forge.explicit.settled_cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:433; count
        "agentstudio.performance.forge.explicit.settled_completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:435; count
        "agentstudio.performance.forge.explicit.settled_failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:437; count
        "agentstudio.performance.forge.explicit.settled_obsolete.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:410; count
        "agentstudio.performance.forge.input.automatic.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:412; count
        "agentstudio.performance.forge.input.follow_up.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:411; count
        "agentstudio.performance.forge.input.manual.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:485; occupancy
        "agentstudio.performance.forge.physical.active.maximum",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:487; occupancy
        "agentstudio.performance.forge.physical.pending.maximum",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:458; count
        "agentstudio.performance.forge.publication.equal.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:460; count
        "agentstudio.performance.forge.publication.invalidated.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:456; count
        "agentstudio.performance.forge.publication.published.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:471; count
        "agentstudio.performance.forge.query.alias_batch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:475; count
        "agentstudio.performance.forge.query.complete_plan.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:469; count
        "agentstudio.performance.forge.query.demanded_branch.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:477; count
        "agentstudio.performance.forge.query.rejected_plan.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:473; count
        "agentstudio.performance.forge.query.returned_node.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:479; count
        "agentstudio.performance.forge.recovery.rate_limited.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:483; count
        "agentstudio.performance.forge.recovery.recovered.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:481; count
        "agentstudio.performance.forge.recovery.unavailable.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:519; duration
        "agentstudio.performance.forge.settlement.deadline.next_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:517; occupancy
        "agentstudio.performance.forge.settlement.deadline.overdue.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:513; occupancy
        "agentstudio.performance.forge.settlement.pending.active_follow_up.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:511; occupancy
        "agentstudio.performance.forge.settlement.pending.capacity.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:507; occupancy
        "agentstudio.performance.forge.settlement.pending.future.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:509; occupancy
        "agentstudio.performance.forge.settlement.pending.ready.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:505; occupancy
        "agentstudio.performance.forge.settlement.pending.total.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:515; occupancy
        "agentstudio.performance.forge.settlement.pending.unclassified.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:503; occupancy
        "agentstudio.performance.forge.settlement.physical.active.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:448; occupancy
        "agentstudio.performance.forge.validation.current.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:450; count; tally, not ordinal
        "agentstudio.performance.forge.validation.stale_generation.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:452; count
        "agentstudio.performance.forge.validation.stale_origin.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgePerformanceRecording.swift:454; count
        "agentstudio.performance.forge.validation.stale_scope.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:66; occupancy
        "agentstudio.performance.git.active_follow_up.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+Telemetry.swift:42; duration
        "agentstudio.performance.git.admission_to_status.elapsed_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:204; count
        "agentstudio.performance.git.aggregate.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:264; occupancy
        "agentstudio.performance.git.aggregate.continuity.authority.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:266; duration
        "agentstudio.performance.git.aggregate.continuity.authority.oldest_checkpoint_age_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:230; count
        "agentstudio.performance.git.aggregate.continuity.baseline.accepted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:228; count
        "agentstudio.performance.git.aggregate.continuity.baseline.prepared.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:232; count
        "agentstudio.performance.git.aggregate.continuity.baseline.rejected.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:254; count
        "agentstudio.performance.git.aggregate.continuity.fallback.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:256; count
        "agentstudio.performance.git.aggregate.continuity.fallback.coalesced.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:236; count
        "agentstudio.performance.git.aggregate.continuity.mutation_invalidated.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:260; count
        "agentstudio.performance.git.aggregate.continuity.physical.detail_read_avoided.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:258; count
        "agentstudio.performance.git.aggregate.continuity.physical.fact_read_avoided.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:234; count
        "agentstudio.performance.git.aggregate.continuity.renewed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:248; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.event_stream_uncertain.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:244; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.identity_changed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:246; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.mutation_observed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:240; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.registration_missing.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:242; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.registration_replaced.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:252; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.shutdown.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:250; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.stream_start_failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:238; count
        "agentstudio.performance.git.aggregate.continuity.uncertainty.unsupported_observation.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:206; count
        "agentstudio.performance.git.aggregate.dropped_subscriber.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:205; count
        "agentstudio.performance.git.aggregate.event_posted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:218; count
        "agentstudio.performance.git.aggregate.explicit.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:226; count
        "agentstudio.performance.git.aggregate.explicit.settled_cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:220; count
        "agentstudio.performance.git.aggregate.explicit.settled_completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:222; count
        "agentstudio.performance.git.aggregate.explicit.settled_failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:224; count
        "agentstudio.performance.git.aggregate.explicit.settled_obsolete.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:212; count
        "agentstudio.performance.git.aggregate.inactive.automatic_intent_removed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:216; count
        "agentstudio.performance.git.aggregate.inactive.automatic_source_started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:214; count
        "agentstudio.performance.git.aggregate.inactive.required_intent_retained.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:262; count
        "agentstudio.performance.git.aggregate.pending.maximum",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:263; count
        "agentstudio.performance.git.aggregate.running.maximum",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:208; count
        "agentstudio.performance.git.aggregate.snapshot_equal.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:210; count
        "agentstudio.performance.git.aggregate.suppressed_input.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:202; count
        "agentstudio.performance.git.aggregate.visibility_admitted_uncovered.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:196; count
        "agentstudio.performance.git.aggregate.visibility_batched.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:200; count
        "agentstudio.performance.git.aggregate.visibility_superseded.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryPerformanceRecording.swift:198; count
        "agentstudio.performance.git.aggregate.visibility_tier_deferred.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:73; occupancy
        "agentstudio.performance.git.background_only_automatic.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:75; occupancy
        "agentstudio.performance.git.background_only_automatic_deadline.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:77; occupancy
        "agentstudio.performance.git.background_only_automatic_owned.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:79; occupancy
        "agentstudio.performance.git.background_only_resolved_visible_tier.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+StatusBackoff.swift:261; duration
        "agentstudio.performance.git.backoff_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:65; occupancy
        "agentstudio.performance.git.capacity_pending.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:62; occupancy
        "agentstudio.performance.git.future_automatic.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:63; occupancy
        "agentstudio.performance.git.future_failure.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:69; occupancy
        "agentstudio.performance.git.inactive_automatic_deadline.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:71; count
        "agentstudio.performance.git.inactive_automatic_source_start.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:15; count
        "agentstudio.performance.git.input_path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:61; occupancy
        "agentstudio.performance.git.logical_debt.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:58; occupancy
        "agentstudio.performance.git.logical_pending.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:60; occupancy
        "agentstudio.performance.git.logical_running.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:82; duration
        "agentstudio.performance.git.next_deadline_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:81; duration
        "agentstudio.performance.git.oldest_preparation_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:68; occupancy
        "agentstudio.performance.git.overdue_deadline.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:24; count
        "agentstudio.performance.git.pathspec.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+StatusBackoff.swift:265; occupancy
        "agentstudio.performance.git.pending.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+PathQuarantine.swift:131; occupancy
        "agentstudio.performance.git.quarantined.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:64; occupancy
        "agentstudio.performance.git.ready_pending.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:59; occupancy
        "agentstudio.performance.git.retry_pending.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+StatusBackoff.swift:266; occupancy
        "agentstudio.performance.git.running.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+Telemetry.swift:35; count
        "agentstudio.performance.git.status.consecutive_failure.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+Telemetry.swift:38; duration
        "agentstudio.performance.git.status.duration_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:20; count
        "agentstudio.performance.git.suppressed_git_internal_path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:19; count
        "agentstudio.performance.git.suppressed_ignored_path.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+LogicalDebt.swift:67; occupancy
        "agentstudio.performance.git.unclassified_pending.count",
        // Sources/AgentStudio/App/IPCComposition/AgentStudioIPCPaneContextAdapter.swift:193; duration
        "agentstudio.performance.ipc.pane_context_read.detail_elapsed_ms",
        // Sources/AgentStudio/App/IPCComposition/AgentStudioIPCPaneContextAdapter.swift:195; size
        "agentstudio.performance.ipc.pane_context_read.reply_bytes",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:3274; count
        "agentstudio.performance.management_layer.pane.count",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:3275; count
        "agentstudio.performance.management_layer.tab.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:594; count
        "agentstudio.performance.pane.association_boot.backfilled.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:603; count
        "agentstudio.performance.pane.association_boot.changed.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:597; count
        "agentstudio.performance.pane.association_boot.dangling_cleared.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:600; count
        "agentstudio.performance.pane.association_boot.free_nil.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:588; count
        "agentstudio.performance.pane.association_boot.pane.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:591; count
        "agentstudio.performance.pane.association_boot.retained_known.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActionExecution.swift:153; count
        "agentstudio.performance.pane_action.pane.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActionExecution.swift:154; count
        "agentstudio.performance.pane_action.tab.count",
        // Sources/AgentStudio/App/PaneContext/PaneContextPopoverPerformance.swift:66; duration
        "agentstudio.performance.pane_context.popover.apply_commit_elapsed_ms",
        // Sources/AgentStudio/App/PaneContext/PaneContextPopoverPerformance.swift:50; duration
        "agentstudio.performance.pane_context.popover.projection_elapsed_ms",
        // Sources/AgentStudio/App/PaneContext/PaneContextPopoverPerformance.swift:38; count
        "agentstudio.performance.pane_context.popover.text_layout.count",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:635; count
        "agentstudio.performance.pane_tab_layout.pane.count",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:637; count
        "agentstudio.performance.pane_tab_layout.subview.count",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:636; count
        "agentstudio.performance.pane_tab_layout.tab.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActiveTabRestore.swift:77; count
        "agentstudio.performance.pane_view_restore.pane.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActiveTabRestore.swift:79; count
        "agentstudio.performance.pane_view_restore.tab.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActiveTabRestore.swift:78; count
        "agentstudio.performance.pane_view_restore.visible_pane.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioProcessMemorySampler.swift:12; occupancy
        "agentstudio.performance.process.malloc.blocks_in_use",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioProcessMemorySampler.swift:14; size
        "agentstudio.performance.process.malloc.maximum_size_in_use_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioProcessMemorySampler.swift:17; size
        "agentstudio.performance.process.malloc.size_allocated_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioProcessMemorySampler.swift:13; size
        "agentstudio.performance.process.malloc.size_in_use_bytes",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:97; count
        "agentstudio.performance.remote_reference.admission.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:99; count
        "agentstudio.performance.remote_reference.admission.capacity_deferred.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:137; count
        "agentstudio.performance.remote_reference.cleanup.failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:135; count
        "agentstudio.performance.remote_reference.cleanup.succeeded.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:93; count
        "agentstudio.performance.remote_reference.demand.changed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:95; count
        "agentstudio.performance.remote_reference.demand.cleared.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:103; count
        "agentstudio.performance.remote_reference.execution.automatic_without_demand_started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:123; count
        "agentstudio.performance.remote_reference.execution.cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:121; count
        "agentstudio.performance.remote_reference.execution.failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:119; count
        "agentstudio.performance.remote_reference.execution.promotion_completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:117; count
        "agentstudio.performance.remote_reference.execution.promotion_started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:115; count
        "agentstudio.performance.remote_reference.execution.staging_completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:101; count
        "agentstudio.performance.remote_reference.execution.staging_started.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:105; count
        "agentstudio.performance.remote_reference.explicit.admitted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:113; count
        "agentstudio.performance.remote_reference.explicit.settled_cancelled.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:107; count
        "agentstudio.performance.remote_reference.explicit.settled_completed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:109; count
        "agentstudio.performance.remote_reference.explicit.settled_failed.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:111; count
        "agentstudio.performance.remote_reference.explicit.settled_obsolete.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:133; count
        "agentstudio.performance.remote_reference.publication.invalidated.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:129; count
        "agentstudio.performance.remote_reference.publication.local_accepted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:131; count
        "agentstudio.performance.remote_reference.publication.promoted.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:172; duration
        "agentstudio.performance.remote_reference.settlement.deadline.next_ms",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:170; occupancy
        "agentstudio.performance.remote_reference.settlement.deadline.overdue.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:166; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.active_follow_up.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:164; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.capacity.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:160; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.future.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:162; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.ready.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:158; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.total.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:168; occupancy
        "agentstudio.performance.remote_reference.settlement.pending.unclassified.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:156; occupancy
        "agentstudio.performance.remote_reference.settlement.physical.active.current",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:125; occupancy
        "agentstudio.performance.remote_reference.validation.current.count",
        // Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferencePerformanceRecording.swift:127; count
        "agentstudio.performance.remote_reference.validation.obsolete.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:133; occupancy
        "agentstudio.performance.renderer.active.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:135; occupancy
        "agentstudio.performance.renderer.close_undo.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:141; count
        "agentstudio.performance.renderer.created.delta",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:130; count
        "agentstudio.performance.renderer.created.total",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:143; count
        "agentstudio.performance.renderer.freed.delta",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:132; count
        "agentstudio.performance.renderer.freed.total",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:134; occupancy
        "agentstudio.performance.renderer.hidden.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:136; occupancy
        "agentstudio.performance.renderer.live.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:137; occupancy
        "agentstudio.performance.renderer.manager_owned.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:138; occupancy
        "agentstudio.performance.renderer.orphan_candidate.current",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:102; count
        "agentstudio.performance.renderer.reconcile.applied",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:103; count
        "agentstudio.performance.renderer.reconcile.equal",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:105; count
        "agentstudio.performance.renderer.reconcile.equal_since_last_emit",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:104; count
        "agentstudio.performance.renderer.reconcile.missing",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:142; count
        "agentstudio.performance.renderer.released.delta",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:131; count
        "agentstudio.performance.renderer.released.total",
        // Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:374; count
        "agentstudio.performance.repo_explorer.command_resolution.count",
        // Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:377; count
        "agentstudio.performance.repo_explorer.command_reused.count",
        // Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:433; count
        "agentstudio.performance.repo_explorer.interval.count",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:457; count
        "agentstudio.performance.repo_explorer.native_table_pilot.baseline_measurement.count",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:463; duration
        "agentstudio.performance.repo_explorer.native_table_pilot.baseline_p95_ms",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:460; count
        "agentstudio.performance.repo_explorer.native_table_pilot.doubled_measurement.count",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:466; duration
        "agentstudio.performance.repo_explorer.native_table_pilot.doubled_p95_ms",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:448; count
        "agentstudio.performance.repo_explorer.native_table_pilot.drain_completed.count",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:445; count
        "agentstudio.performance.repo_explorer.native_table_pilot.liveness_projection.count",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:513; duration
        "agentstudio.performance.repo_explorer.native_table_pilot.membership_p95_ms",
        // Sources/AgentStudio/Features/RepoExplorer/Diagnostics/RepoExplorerNativeTablePilot.swift:451; count
        "agentstudio.performance.repo_explorer.native_table_pilot.template_pair.count",
        // Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:368; count
        "agentstudio.performance.repo_explorer.visible_set.count",
        // Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:371; count
        "agentstudio.performance.repo_explorer.visible_set_delta.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:59; count
        "agentstudio.performance.repository_fact_demand.activity.boundary_reclassified.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:65; occupancy; occupancy, not sequence
        "agentstudio.performance.repository_fact_demand.activity.hydration_unclassified.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:71; occupancy
        "agentstudio.performance.repository_fact_demand.activity.inactive_repository.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:93; occupancy
        "agentstudio.performance.repository_fact_demand.activity.inactive_worktree.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:63; count
        "agentstudio.performance.repository_fact_demand.activity.pane_reactivated.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:61; count
        "agentstudio.performance.repository_fact_demand.activity.recency_reactivated.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:69; occupancy
        "agentstudio.performance.repository_fact_demand.activity.unknown_repository.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:75; occupancy
        "agentstudio.performance.repository_fact_demand.activity.unknown_worktree.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:67; occupancy
        "agentstudio.performance.repository_fact_demand.activity.warm_repository.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:73; occupancy
        "agentstudio.performance.repository_fact_demand.activity.warm_worktree.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:54; count
        "agentstudio.performance.repository_fact_demand.cleared.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:50; count
        "agentstudio.performance.repository_fact_demand.content_equal.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:52; count
        "agentstudio.performance.repository_fact_demand.delivered.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:97; occupancy
        "agentstudio.performance.repository_fact_demand.inactive.forge_suppressed.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:95; occupancy
        "agentstudio.performance.repository_fact_demand.inactive.remote_suppressed.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:83; count
        "agentstudio.performance.repository_fact_demand.pipeline.applied.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:87; occupancy
        "agentstudio.performance.repository_fact_demand.pipeline.unknown_background_only.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:91; occupancy
        "agentstudio.performance.repository_fact_demand.pipeline.unknown_forge_demand.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:89; occupancy
        "agentstudio.performance.repository_fact_demand.pipeline.unknown_remote_demand.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:85; occupancy
        "agentstudio.performance.repository_fact_demand.pipeline.unknown_worktree.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:48; count
        "agentstudio.performance.repository_fact_demand.projected.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:56; count
        "agentstudio.performance.repository_fact_demand.rejected_after_shutdown.count",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:77; occupancy
        "agentstudio.performance.repository_fact_demand.unknown.background_only.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:81; occupancy
        "agentstudio.performance.repository_fact_demand.unknown.forge_demand.current",
        // Sources/AgentStudio/App/Coordination/RepositoryFactDemandPerformanceRecording.swift:79; occupancy
        "agentstudio.performance.repository_fact_demand.unknown.remote_demand.current",
        // Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator+ScopedTopology.swift:78; count
        "agentstudio.performance.repository_lifecycle.changed_family.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator+Retention.swift:82; count
        "agentstudio.performance.repository_lifecycle.collected_location.count",
        // Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator+Retention.swift:83; duration
        "agentstudio.performance.repository_lifecycle.mainactor_held_ms",
        // Sources/AgentStudio/Core/State/MainActor/Coordination/RepositoryLifecycleReconciliation.swift:39; count
        "agentstudio.performance.repository_lifecycle.observation.count",
        // Sources/AgentStudio/Core/State/MainActor/Coordination/RepositoryLifecycleReconciliation.swift:38; count
        "agentstudio.performance.repository_lifecycle.repository.count",
        // Sources/AgentStudio/App/Boot/AppDelegate+ShellCommandHandling.swift:367; count
        "agentstudio.performance.repository_update.applicable_source.count",
        // Sources/AgentStudio/App/Boot/AppDelegate+ShellCommandHandling.swift:371; count
        "agentstudio.performance.repository_update.terminal_source.count",
        // Sources/AgentStudio/App/Boot/AppDelegate+ShellCommandHandling.swift:369; count
        "agentstudio.performance.repository_update.unsettled_source.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+Restore.swift:23; count
        "agentstudio.performance.restore.execution.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+Restore.swift:25; duration
        "agentstudio.performance.restore.main_thread.elapsed_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+Restore.swift:24; count
        "agentstudio.performance.restore.main_thread.execution.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:41; count
        "agentstudio.performance.runtime_delivery.eventbus_active_delivery_debt.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:55; count
        "agentstudio.performance.runtime_delivery.eventbus_active_subscriber.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:49; count
        "agentstudio.performance.runtime_delivery.eventbus_live_dropped.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:51; count
        "agentstudio.performance.runtime_delivery.eventbus_replay_dropped.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:53; count
        "agentstudio.performance.runtime_delivery.eventbus_retired_undelivered.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:45; count
        "agentstudio.performance.runtime_delivery.runtime_channel_outbound_dropped.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:39; count
        "agentstudio.performance.runtime_delivery.runtime_channel_outbound_pending.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:47; count
        "agentstudio.performance.runtime_delivery.runtime_channel_retired_undelivered.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/RuntimeDeliveryPerformanceReporter.swift:43; count
        "agentstudio.performance.runtime_delivery.total_pending.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:38; size
        "agentstudio.performance.scrollback.pass.captured.bytes",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; cancelled tally
        "agentstudio.performance.scrollback.pass.outcome.cancelled.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; deadline tally
        "agentstudio.performance.scrollback.pass.outcome.deadline_exceeded.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; empty tally
        "agentstudio.performance.scrollback.pass.outcome.empty.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; ceiling tally
        "agentstudio.performance.scrollback.pass.outcome.exceeded_ceiling.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; exit-status cases summed
        "agentstudio.performance.scrollback.pass.outcome.exited_nonzero.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; invalid UTF-8 tally
        "agentstudio.performance.scrollback.pass.outcome.invalid_utf8.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; previous retained tally
        "agentstudio.performance.scrollback.pass.outcome.keep_previous.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; errno cases summed
        "agentstudio.performance.scrollback.pass.outcome.launch_failed.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; read-failure tally
        "agentstudio.performance.scrollback.pass.outcome.read_failed.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; retired tally
        "agentstudio.performance.scrollback.pass.outcome.retired.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; unchanged tally
        "agentstudio.performance.scrollback.pass.outcome.unchanged.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; write-failure tally
        "agentstudio.performance.scrollback.pass.outcome.write_failed.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:48; count; committed tally
        "agentstudio.performance.scrollback.pass.outcome.written.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:37; count
        "agentstudio.performance.scrollback.pass.pane.count",
        // Sources/AgentStudio/Features/Terminal/Restore/ScrollbackPerformanceRecording.swift:39; size; committed persisted form
        "agentstudio.performance.scrollback.pass.written.bytes",
        // Sources/AgentStudio/Features/InboxNotification/Views/InboxNotificationSidebarView.swift:296; count
        "agentstudio.performance.sidebar.cancellation.count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift:61; count
        "agentstudio.performance.sidebar.collapsed_group.count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:340; count
        "agentstudio.performance.sidebar.group.count",
        // Sources/AgentStudio/Features/InboxNotification/Views/InboxNotificationSidebarView.swift:438; count
        "agentstudio.performance.sidebar.input.count",
        // Sources/AgentStudio/Features/InboxNotification/Views/InboxNotificationSidebarView.swift:414; duration
        "agentstudio.performance.sidebar.mainactor_apply_elapsed_ms",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:655; count
        "agentstudio.performance.sidebar.proof.initial_readback.native_row_count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:654; count
        "agentstudio.performance.sidebar.proof.initial_readback.represented_row_count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:462; count
        "agentstudio.performance.sidebar.proof.ordered_command.count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:312; count
        "agentstudio.performance.sidebar.proof.ordered_command_baseline",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:772; count
        "agentstudio.performance.sidebar.proof.ordered_command_completion",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:747; count
        "agentstudio.performance.sidebar.proof.readback.inactive_repository_header.count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:749; count
        "agentstudio.performance.sidebar.proof.readback.suppressed_repository_fact_row.count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:751; count
        "agentstudio.performance.sidebar.proof.readback.updating_repository_header.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:458; count
        "agentstudio.performance.sidebar.proof.terminal_input.count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:310; count
        "agentstudio.performance.sidebar.proof.terminal_input_baseline",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:770; count
        "agentstudio.performance.sidebar.proof.terminal_input_completion",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:460; count
        "agentstudio.performance.sidebar.proof.terminal_output.count",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:311; count
        "agentstudio.performance.sidebar.proof.terminal_output_baseline",
        // Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift:771; count
        "agentstudio.performance.sidebar.proof.terminal_output_completion",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift:60; size
        "agentstudio.performance.sidebar.query_character.count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:388; count
        "agentstudio.performance.sidebar.readback.represented_row_count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift:59; count
        "agentstudio.performance.sidebar.repo.count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter+InputLifecycle.swift:351; duration
        "agentstudio.performance.sidebar.request_build_mainactor_elapsed_ms",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:353; duration
        "agentstudio.performance.sidebar.row_index_elapsed_ms",
        // Sources/AgentStudio/App/Windows/MainSplitViewController.swift:761; size
        "agentstudio.performance.sidebar.split_width",
        // Sources/AgentStudio/Features/InboxNotification/Views/InboxNotificationSidebarView.swift:378; count
        "agentstudio.performance.sidebar.stale_discard.count",
        // Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:337; duration
        "agentstudio.performance.sidebar.total_worker_elapsed_ms",
        // Sources/AgentStudio/App/Windows/MainSplitViewController.swift:760; size
        "agentstudio.performance.sidebar.width",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:525; duration
        "agentstudio.performance.startup.layout_settle_to_usable_elapsed_ms",
        // Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:725; count
        "agentstudio.performance.tabbar.affected_item.count",
        // Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:694; duration
        "agentstudio.performance.tabbar.mainactor_held_ms",
        // Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:719; count
        "agentstudio.performance.tabbar.pane.count",
        // Sources/AgentStudio/App/Panes/TabBar/DraggableTabBarHostingView.swift:715; count
        "agentstudio.performance.tabbar.pane_drop.frame.count",
        // Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:691; duration
        "agentstudio.performance.tabbar.queue_wait_ms",
        // Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:716; count
        "agentstudio.performance.tabbar.source_tab.count",
        // Sources/AgentStudio/App/Panes/TabBar/DraggableTabBarHostingView.swift:716; count
        "agentstudio.performance.tabbar.tab.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:624; count
        "agentstudio.performance.terminal.accumulator.equal_suppressed.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:628; count
        "agentstudio.performance.terminal.accumulator.follow_up_drain.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:630; count
        "agentstudio.performance.terminal.accumulator.mainactor_task.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:620; count
        "agentstudio.performance.terminal.accumulator.offered.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:622; count
        "agentstudio.performance.terminal.accumulator.replaced.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:636; occupancy
        "agentstudio.performance.terminal.accumulator.retained_entry.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:638; size
        "agentstudio.performance.terminal.accumulator.retained_size_bytes",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:626; count
        "agentstudio.performance.terminal.accumulator.scheduled_drain.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:632; count
        "agentstudio.performance.terminal.activity_aggregate.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:695; duration
        "agentstudio.performance.terminal.activity_projection.close_read_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:680; duration
        "agentstudio.performance.terminal.activity_projection.round_trip_ms",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:662; count
        "agentstudio.performance.terminal.equal_suppressed.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:672; count
        "agentstudio.performance.terminal.equal_write_suppressed.count",
        // Sources/AgentStudio/App/Panes/PaneTabViewController.swift:1783; count
        "agentstudio.performance.terminal.geometry.visible_terminal.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:634; count
        "agentstudio.performance.terminal.output_advancement.count",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:789; size
        "agentstudio.performance.terminal.surface.cell_height_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:787; size
        "agentstudio.performance.terminal.surface.cell_width_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:784; count
        "agentstudio.performance.terminal.surface.column.count",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:782; size
        "agentstudio.performance.terminal.surface.current_height_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:780; size
        "agentstudio.performance.terminal.surface.current_width_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:778; size
        "agentstudio.performance.terminal.surface.requested_height_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:776; size
        "agentstudio.performance.terminal.surface.requested_width_px",
        // Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:786; count
        "agentstudio.performance.terminal.surface.row.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:566; count; tally, not ordinal
        "agentstudio.performance.topology.index.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:720; count
        "agentstudio.performance.trace_identity.coalesced_request.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:724; count
        "agentstudio.performance.trace_identity.equal_snapshot_suppressed.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:722; count
        "agentstudio.performance.trace_identity.fleet_capture.count",
        // Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:718; count
        "agentstudio.performance.trace_identity.refresh_request.count",
    ]
}
