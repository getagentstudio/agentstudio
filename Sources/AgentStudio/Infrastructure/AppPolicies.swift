import CoreGraphics
import Foundation

package enum AppPolicies {
    package enum Panes {
        package static let activityTimePublishInterval: Duration = .seconds(10)
    }

    package enum IPC {
        package static let maximumTerminalWaitSeconds: Double = 86_400
        /// One spooled notification is one wire frame, so the drainer accepts
        /// exactly what the IPC server would have accepted live. A longer line
        /// could never have been submitted and is malformed by construction.
        package static let spoolDrainMaximumLineBytes: Int = 1_048_576
        /// Deadline on the whole application termination drain. AppKit's
        /// `.terminateLater` has one exit, the reply, so an unbounded await in
        /// the drain does not delay quit — it cancels it.
        package static let shutdownDrainTimeout: Duration = .seconds(2)
    }

    package enum Sessions {
        /// Live ingress bounds. Exceeding either bound discloses the loss on
        /// the request instead of silently dropping the fact.
        package static let maximumPendingIngestionPerPane = 256
        package static let maximumPendingIngestionGlobal = 1024
    }
    package enum BackgroundFactApplyGovernor {
        package static let tickCadence: Duration = .milliseconds(16)
        package static let drainBudget: Duration = .milliseconds(4)
    }

    package enum StartupDeferral {
        package static let maximumWait: Duration = .seconds(10)
    }

    package enum CommandBar {
        package static let maximumHistoryCount: Int = 8
    }

    package enum EntityRecency {
        package static let maximumApplicationPresentationCountPerKind: Int = 15
        package static let maximumWorkspaceRetainedEntityCount: Int = 15
        /// Application recency retention is bounded per kind rather than in
        /// total. Presentation resolves each kind separately and drops entities
        /// whose repository or worktree no longer exists, so a shared total cap
        /// would let one busy kind starve the other out of its own list. The
        /// bound sits well above `maximumApplicationPresentationCountPerKind`
        /// to absorb those unresolvable drops while keeping retention a
        /// constant instead of a function of churn across the activity horizon.
        package static let maximumApplicationRetainedEntityCountPerKind: Int = 64
        package static let applicationActivityHorizon: TimeInterval = 60 * 24 * 60 * 60
        package static let strongBlueDuration: TimeInterval = 10 * 60
        package static let mediumBlueDuration: TimeInterval = 60 * 60
        package static let mutedBlueDuration: TimeInterval = 12 * 60 * 60
        package static let faintBlueDuration: TimeInterval = 24 * 60 * 60
    }

    package enum RepoExplorer {
        package static let inactiveRefreshRevealDuration: Duration = .seconds(30)
        package static let activeActivityDuration: TimeInterval = 60
        package static let justNowActivityDuration: TimeInterval = 10 * 60
        package static let lastHourActivityDuration: TimeInterval = 60 * 60
        package static let recentActivityDuration: TimeInterval = 7 * 24 * 60 * 60
    }

    package enum SidebarProjection {
        package static let cancellationItemStride: Int = 256
        package static let cancellationGroupStride: Int = 64
        package static let paneRecencyDisplayCadence: Duration = .seconds(60)

        package enum Trigger: String, Equatable, Sendable {
            case groupingSwitch = "grouping_switch"
            case surfaceSwitch = "surface_switch"
            case search
            case sortOrder = "sort_order"
            case collapseToggle = "collapse_toggle"
            case dataRefresh = "data_refresh"
            case startupDiagnostic = "startup_diagnostic"
        }
    }

    package enum SidebarPerformanceProof {
        package static let policyID = "strict-sidebar-cpu"
        package static let policyVersion: Int = 6
        package static let nativeTablePilotPolicyID = "sidebar-native-table-pilot"
        package static let nativeTablePilotPolicyVersion: Int = 1
        package static let repositoryCount: Int = 150
        package static let worktreeCount: Int = 180
        package static let doubledWorktreeCount: Int = 360
        package static let tabCount: Int = 12
        package static let paneCount: Int = 36
        package static let activePTYCount: Int = 1
        package static let strictWatchedRootURLs: [URL] = [
            URL(fileURLWithPath: "/Users/shravansunder/Documents/dev/open-source", isDirectory: true),
            URL(fileURLWithPath: "/Users/shravansunder/Documents/dev/project-dev", isDirectory: true),
        ]
        package static let strictTabCount: Int = 5
        package static let strictPaneModelCount: Int = 20
        package static let zeroPTYExpectedSessionCount: Int = 0
        package static let zmxInventoryInterval: Duration = .seconds(5)
        package static let fixturePreparationTimeout: Duration = .seconds(300)
        package static let fixtureStateObservationInterval: Duration = .milliseconds(10)
        package static let representedRowCount: Int = 24
        package static let warmupTransactionCountPerScale: Int = 20
        package static let measuredTransactionCountPerScale: Int = 200
        package static let maximumMembershipP95Milliseconds: Double = 4
        package static let maximumDoubledOffscreenGrowthPercent: Double = 20
        package static let nativeTablePilotCompletionTimeout: Duration = .seconds(30)
        package static let scaleWorktreeCounts = [worktreeCount, doubledWorktreeCount]
        package static let invalidatesWholePopulationOnFailure = true
        package static let fixtureQuery = "worktree"
        package static let populatedFixtureTabCount: Int = 2
        package static let idleProcessCPUP99MaximumPercent: Double = 10
        package static let actionProcessCPUP95MaximumPercent: Double = 20
        package static let sampleInterval: Duration = .seconds(1)
        package static let metricsExportInterval: Duration = Diagnostics.otlpMetricsExportInterval
        package static let requiredIdleUsableSampleCount: Int = 1000
        package static let requiredSuccessfulActionCount: Int = 100
        package static let requiredActionBearingSampleCount: Int = 200
        package static let searchCharacterCount: Int = 8
        package static let searchCharacterInterval: Duration = .milliseconds(100)
        package static let quiescenceInterval: Duration = .seconds(5)
        package static let actionReadbackTimeout: Duration = .seconds(5)
        package static let maximumSamplerGap: Duration = .milliseconds(1250)
        package static let maximumActionSampleBoundaryOffset: Duration = .milliseconds(50)
        package static let actionSampleStartOffset: Duration = .milliseconds(20)
        package static let maximumDiagnosticCPUP95DeltaPercentagePoints: Double = 5
        package static let maximumDiagnosticInteractionP95GrowthPercent: Double = 10
        package static let gitStatusPhysicalLimit = GitRefresh.defaultDetachedStatusReadLimit
        package static let remoteReferencePhysicalLimit = RemoteReferenceRefresh.maximumConcurrentFetches
        package static let forgePhysicalLimit = ForgeRefresh.maximumConcurrentProviderRequests
        package static let gitMaximumSettlementInterval =
            GitRefresh.defaultPolicy.maximumSettlementInterval
        package static let standardTraceTags = ["performance", "app.startup", "terminal.startup"]
        package static let diagnosticTraceTags = [
            "performance", "atoms", "app.startup", "terminal.startup",
        ]
        package static let idlePopulationNames = ["zero_pty_idle"]
        package static let actionPopulationNames = ["search_clear", "grouping", "hide_show", "tab_switch"]
    }

    package enum Diagnostics {
        package static let traceEventQueueBufferLimit: Int = 4096
        package static let repoExplorerExactAttributionRecordLimit: Int = 2048
        package static let repoExplorerScrollBurstSeparationNanoseconds: UInt64 = 250_000_000
        /// Native hot-path performance facts must shed before reaching
        /// swift-otel. Topology lookup telemetry is informational, so repeated
        /// derived/UI reads should never be able to saturate the exporter.
        package static let topologyLookupTraceAdmissionWindow: Duration = .seconds(1)
        package static let topologyLookupTraceAdmissionLimit: Int = 32
        /// Pane association maintenance is an often lane because terminal CWD
        /// facts can arrive repeatedly. Shed before the trace queue while
        /// retaining enough outcome samples to diagnose association churn.
        /// Atom reads are the highest-frequency call in the atom layer: every
        /// family lookup is one. Emission must therefore be bounded by a
        /// window rather than by call rate, or enabling the `atoms` tag would
        /// consume the trace queue headroom that keeps the exporter alive.
        package static let atomReadTraceAdmissionWindow: Duration = .seconds(1)
        package static let atomReadTraceAdmissionLimit: Int = 32
        package static let paneAssociationTraceAdmissionWindow: Duration = .seconds(1)
        package static let paneAssociationTraceAdmissionLimit: Int = 64
        /// Downstream swift-otel log batch queue. swift-otel drops newly
        /// emitted logs once this fills, so keep it above the app trace event
        /// queue and let the app-side queue remain the oldest-shedding layer.
        package static let otlpLogMaxQueueSize: Int = 8192
        package static let otlpLogMaxExportBatchSize: Int = 1024
        package static let otlpLogScheduleDelay: Duration = .seconds(1)
        package static let otlpTraceScheduleDelay: Duration = .seconds(1)
        package static let otlpMetricsExportInterval: Duration = .seconds(60)
        package static let otlpExportTimeout: Duration = .seconds(30)
    }

    package enum Bridge {
        /// Settled results retain their slots until the worker acknowledges them.
        package static let maximumOrdinaryProductOperations: Int = 32
        package static let maximumHumanWaitProductOperations: Int = 2
        /// Reserved at mutation admission so unknown outcomes remain observable
        /// without consuming ordinary result slots indefinitely.
        package static let maximumProductMutationWatches: Int = 64
        package static let productMutationObservationDeadline: Duration = .seconds(4)
        package static let productRetirementQuiescenceDeadline: Duration = .seconds(4)
        package static let productOperationSettlementDeadline: Duration = .seconds(4)
        /// The worker allows the native settlement deadline to fire first.
        package static let productWorkerSettlementDeadline: Duration = .seconds(5)
        /// Bounds native delivery into a page independently of a cooperative WebKit reply.
        package static let productBootstrapDeliveryProgressDeadline: Duration = .seconds(5)
        package static let reviewBuildProgressDeadline: Duration = .seconds(5)
        /// A finite content read must make response or verified body progress.
        package static let contentProgressDeadline: Duration = .seconds(5)
        /// A page content receipt must be acknowledged independently of body progress.
        package static let productContentAcknowledgementDeadline: Duration = .seconds(5)
        /// Available through document-start configuration before any product session response.
        package static let productPageBootstrapDeadline: Duration = .seconds(5)
        package static let productPageReadyAcknowledgementDeadline: Duration = .seconds(5)
        package static let productAdmissionRetryCount: Int = 2
        /// N3 bounds in-transit metadata parts independently of the producer queue.
        package static let productViewCreditParts: Int = 8
        package static let productViewCreditBytes: Int = 512 * 1024
        package static let productViewMaximumDirtyKeys: Int = 4096
        package static let productViewAcknowledgementDeadline: Duration = .seconds(4)
        /// An incomplete W4 side bank must make begin/part/complete progress.
        package static let productViewBatchProgressDeadline: Duration = .seconds(5)
        /// Keeps an open WebKit metadata response moving after its last product frame.
        package static let streamKeepaliveInterval: Duration = .milliseconds(350)
        package static let productViewMaximumConsecutiveResnapshots: Int = 3
        /// PR1 interim: metadata budget for issued File descriptors that are no
        /// longer newest. PR2's installed-selection lease replaces this cache.
        package static let fileRetainedDescriptorMaximumCount: Int = 128
        package static let fileRetainedDescriptorMaximumEncodedBytes: Int = 256 * 1024
        package static let fileRefreshMaximumAutomaticRetryCount: Int = 1
        package static let fileSurfaceMaximumUnchangedInputSupersessions: Int = 1
        /// Caps automatic same-basis restarts after uncertified File interruptions.
        package static let fileSurfaceInterruptionRestartLimit: Int = 3
        /// Observability-only custody for pairing Bridge lifecycle starts and
        /// terminals. This never controls product work or retry behavior.
        package static let operationLifecycleTerminalWindow: Duration = .seconds(30)
        package static let operationLifecycleMaximumTrackedStageAttempts: Int = 4096
        /// Command outcomes are correlation aids for active annotation editors,
        /// not durable history. Keep a bounded window in the projection Atom.
        package static let worktreeAnnotationMaximumRetainedCommandOutcomes: Int = 128
        package static let worktreeAnnotationMaximumOutputHistorySummaries: Int = 128
        /// Inspection descriptors are short-lived content capabilities. Retain
        /// only metadata for a bounded number of not-yet-opened outputs; exact
        /// output bytes remain authoritative in local.sqlite.
        package static let worktreeAnnotationMaximumIssuedOutputDescriptors: Int = 64
        package static let worktreeAnnotationMaximumDiscoverySessions: Int = 128
        package static let worktreeAnnotationMaximumSourceCandidateCount: Int = 256
        package static let worktreeAnnotationMaximumSourceFileByteCount: Int = 1 * 1024 * 1024
        package static let worktreeAnnotationContinuityMaximumCommitCount: Int = 10
        package static let worktreeAnnotationContinuityMaximumTraversalCount: Int = 256
        package static let reviewComparisonTargetRecencyWindow: Duration = .seconds(30 * 24 * 60 * 60)
        package static let reviewComparisonTargetMaximumRows: Int = 2000
        package static let reviewComparisonTargetMaximumEncodedBytes: Int = 1 * 1024 * 1024
        package static let reviewRefreshPromotionImportedCommitCount: Int = 10
        package static let reviewRefreshPromotionAffectedFileCount: Int = 25
        package static let reviewRefreshPromotionChangedLineCount: Int = 1000
        /// Commit ancestry proof is only needed when the imported range stays
        /// below the promotion threshold. A deeper or divergent walk becomes
        /// conservative promoted-unknown instead of retaining a Git slot.
        package static let reviewRefreshImpactMaximumCommitTraversalCount: Int = 256
        /// Impact classification never materializes line diffs for bodies above
        /// this cap. Oversized bodies promote conservatively.
        package static let reviewRefreshImpactMaximumDiffableBlobByteCount: Int64 = 1 * 1024 * 1024
        /// Retention cap for one content body: a single item must never evict
        /// the whole byte cache, and larger bodies render as oversized.
        package static let contentMaxBytesPerItem: Int = 16 * 1024 * 1024
        /// Keep ordinary File/Review read and cancellation quanta independent of
        /// the larger wire envelope required for complete annotation records.
        package static let contentProducerChunkBytes: Int = 128 * 1024
        /// Desktop byte-cache residency target. At 128MB this keeps at least
        /// 8 max-size content bodies warm, avoiding re-fetch/re-highlight
        /// churn without letting one item define total retention.
        package static let contentCacheMaxBytes: Int = 128 * 1024 * 1024
        package static let defaultGitDataPlaneReadTimeout: Duration = .seconds(30)
        /// Recovery guardrail for queued Bridge Git reads in each operation
        /// class. S10b owns workload calibration; this value prevents the
        /// pre-calibration scheduler from accepting an unbounded backlog.
        package static let gitReadSchedulerMaxQueuedOperationsPerClass: Int = 64
        /// Recovery guardrail for callers sharing one identical physical Git
        /// read. S10b may recalibrate this after the multi-worktree workload.
        package static let gitReadSchedulerMaxLogicalWaitersPerOperation: Int = 16
        /// File tree admission may enrich from full git status only when that
        /// read fits inside the native viewer journey budget. On timeout the
        /// tracked-aware filesystem fallback keeps tree publication moving.
        package static let worktreeFileManifestStatusReadTimeout: Duration = .milliseconds(100)
        package static let ipcMaxResponsePayloadBytes: Int = 768 * 1024
        /// Worktree/File metadata window size for the startup snapshot and
        /// continuation tree windows. Provisional until the OD4 profiling
        /// gate graduates it; proof asserts observed windows equal this
        /// constant rather than a literal.
        package static let worktreeFileTreeMetadataWindowRowLimit: Int = 200
        /// Idle no-starvation budget for the metadata lane scheduler: after
        /// this many higher-lane jobs drain while idle work waits, the next
        /// dispatch is one idle batch. Provisional until the OD4 profiling
        /// gate graduates it.
        package static let metadataIdleNoStarvationBudget: Int = 4
        /// Background review content fill yields as soon as this many
        /// selected/visible content requests are pending in the native
        /// scheme handler. The current contract is strict user-interest
        /// reservation: any selected/visible request pauses background fill.
        package static let contentBackgroundFillUserInterestYieldThreshold: Int = 1
        /// Interactive background fill starts with a tiny burst, then admits
        /// one background content request per interval until recent user
        /// interest cools down. The debug-observability-oq4s-1783162673-24877
        /// session saw 2408 background-interest loads in a few minutes while
        /// scrolling; one sustained refill per second keeps active-use fill
        /// near 60/minute, an order-of-magnitude calmer than that session,
        /// while the idle path remains unpaced for startup pre-warm.
        package static let contentBackgroundFillInteractiveBurstBudget: Int = 12
        package static let contentBackgroundFillInteractiveRefillInterval: Duration = .seconds(1)
        package static let contentBackgroundFillInteractiveRefillBudget: Int = 1
        package static let contentBackgroundFillInteractiveCooldown: Duration = .seconds(2)
        /// Per-lane queued-job cap for the metadata lane scheduler. A pane
        /// whose gate never reopens (wedged or dead WebView) must not grow
        /// its queues without bound from watch-driven producers; on overflow
        /// the scheduler drops the lane's oldest job and emits an overflow
        /// drop so the loss is observable, never silent. Recovery is the
        /// normal reset/reopen path, which rebuilds from the manifest.
        package static let metadataSchedulerMaxQueuedJobsPerLane: Int = 256
        /// R46 execution budget for BridgeWeb's main-thread apply pump. The
        /// BridgeWeb mirror is source-scanned by AppPoliciesBridgeTests because
        /// this app cannot import TypeScript constants.
        package static let applyPumpFrameBudgetMilliseconds: Int = 8
        package static let applyPumpMaxUnitsPerFrame: Int = 4
        package static let applyPumpStaleScanLimit: Int = 64
        package static let applyPumpNoStarvationSelectedBatchLimit: Int = 3
        package static let selectedApplyInitialWindowLineCount: Int = 1500
    }

    package enum RepositoryRetention {
        package static let collectionBatchLimit = 64
        package static let retryDelay: Duration = .seconds(60)
        package static let durationSeconds: TimeInterval = 30 * 24 * 60 * 60
        package static let reconciliationRetryLimit: Int = 2
    }

    package enum WorkspacePersistence {
        /// Autosave waits for quiet, but never longer than this after the first unsaved change.
        package static let autosaveMaximumDelay: Duration = .seconds(2)
        package static let debouncedAutosaveFailureDampingThreshold: Int = 3
        package static let maximumAvailableUndoCloses: Int = 10
        package static let undoGracePeriod: Duration = .seconds(300)
        package static let completedUndoHistoryLimit: Int = 100
        package static let completedUndoPruneBatchSize: Int = 100
        package static let undoDeadlineRetryDelay: Duration = .seconds(5)
        package static let sessionControlTimeout: Duration = .milliseconds(1500)
        package static let maximumSessionControlPayloadBytes: UInt32 = 65_536
        package static let sessionCleanupBatchSize: Int = 32
        package static let sessionCleanupStartupDelay: Duration = .seconds(300)
        package static let sessionCleanupRetryDelay: Duration = .seconds(5)
    }

    package enum TerminalActivation {
        package static let restoreMaximumConcurrentAdmissions: Int = 1
    }

    package enum TerminalNavigation {
        package static let pageFraction: Double = 0.9
        package static let smallStepFraction: Double = 0.33
    }

    package enum TerminalProcessTermination {
        package static let acknowledgementTimeout: Duration = .seconds(2)
    }

    package enum TerminalLocalAction {
        package static let titleMainActorAdmissionSlackNanoseconds: UInt64 = 100_000_000
    }

    /// Bounds for the source-side "last output line" contraction (Contract 7).
    /// The pinned Ghostty C API cannot select the last N written viewport rows,
    /// so one full-viewport read remains a measured exception after this
    /// preflight cell cap. Raw bytes are rejected before String construction.
    package enum TerminalOutputCapture {
        package static let maxLastOutputLineUTF8Bytes: Int = 120
        package static let maxViewportCellsPerSettleRead: Int = 250_000
        package static let maxRawViewportUTF8Bytes: Int = 1_048_576
    }

    package enum NonterminalContentMount {
        package static let maximumMountsPerMainActorTurn: Int = 4
    }

    package enum GitRefresh {
        package static let sharedExactItemFingerprintAlgorithm = "sha256-v1"
        package static let sharedExactItemFingerprintMaximumItemBytes: Int = 8 * 1024 * 1024
        package static let sharedExactItemFingerprintMaximumUniqueItems: Int = 64
        package static let sharedExactItemFingerprintMaximumTransactionBytes: Int = 32 * 1024 * 1024
        package static let statusUnavailableConsecutiveFailureThreshold: Int = 2
        package static let defaultPolicy = Policy(
            minimumAutomaticStartInterval: .milliseconds(300)
        )
        package static let defaultStatusReadTimeout: Duration = .seconds(1)
        package static let defaultDiscoveryReadTimeout: Duration = .seconds(2)
        package static let defaultDetachedStatusReadLimit: Int = 4
        package static let filesystemDebounceWindow: Duration = .milliseconds(500)
        package static let filesystemMaxFlushLatency: Duration = .seconds(10)
        package static let filesystemDerivedCoalescingWindow: Duration = .milliseconds(500)
        package static let visibilityChangeCoalescingWindow: Duration = .milliseconds(200)
        package static let telemetryFlushEventCount: UInt64 = 64

        package struct Policy: Equatable, Sendable {
            package let activePaneCadence: Duration
            package let visibleSidebarCadence: Duration
            package let openPaneCadence: Duration
            package let backgroundCadence: Duration
            package let backgroundStripeCount: Int
            package let maxConcurrentStatusComputes: Int
            package let activePaneMaxConcurrent: Int
            package let visibleSidebarMaxConcurrent: Int
            package let openPaneMaxConcurrent: Int
            package let backgroundMaxConcurrent: Int
            package let visibleSidebarStripeSize: Int
            package let suppressedWorktreeTombstoneLimit: Int
            /// First backoff step applied when a worktree's status compute times
            /// out. The per-worktree circuit breaker doubles this per consecutive
            /// failure up to `statusFailureBackoffMaxDelay`, coalescing file-change
            /// events that arrive during the open window into one deferred refresh.
            package let statusFailureBackoffBaseDelay: Duration
            package let statusFailureBackoffMultiplier: Int
            package let statusFailureBackoffMaxDelay: Duration
            /// Short bounded retry window for shared read-capacity contention. This
            /// is deliberately separate from the failure breaker because a busy
            /// global pool is not evidence that a worktree is unhealthy.
            package let capacityRetryBaseDelay: Duration
            package let capacityRetryJitterMaxDelay: Duration
            /// Maximum changed-path count a file-change batch may carry and still
            /// be refreshed with a pathspec-scoped status. Beyond this the
            /// projector falls back to a full-worktree status, since a very large
            /// pathspec set approaches full-tree walk cost anyway.
            package let maxScopedStatusPathspecCount: Int
            /// Maximum age of a reusable exact line-count detail when status facts
            /// remain equal. A due detail is refreshed without discarding the last
            /// complete accepted candidate.
            package let lineDetailFreshnessInterval: Duration
            /// Process-wide spacing between automatic local-status starts. A
            /// 300ms production interval spreads 148 visible eligibility slots
            /// across 44.4 seconds, leaving duty-gap headroom inside 60 seconds.
            package let minimumAutomaticStartInterval: Duration
            /// Multiplier applied to completed physical duty before another
            /// automatic start may run. Freshness cadence remains the primary
            /// floor; this prevents slow reads from creating continuous duty.
            package let automaticDutyGapMultiplier: Int
            /// Periodic cadence multipliers indexed by consecutive unchanged
            /// results. The default reaches 4x after two equal outcomes, reducing
            /// admissions by 75% while retaining a bounded refresh backstop.
            package let unchangedStatusCadenceMultipliers: [Int]

            package init(
                activePaneCadence: Duration = .seconds(15),
                visibleSidebarCadence: Duration = .seconds(60),
                openPaneCadence: Duration = .seconds(180),
                backgroundCadence: Duration = .seconds(240),
                backgroundStripeCount: Int = 16,
                maxConcurrentStatusComputes: Int = 4,
                activePaneMaxConcurrent: Int = 1,
                visibleSidebarMaxConcurrent: Int = 2,
                openPaneMaxConcurrent: Int = 1,
                backgroundMaxConcurrent: Int = 1,
                visibleSidebarStripeSize: Int = 8,
                suppressedWorktreeTombstoneLimit: Int = 1024,
                statusFailureBackoffBaseDelay: Duration = .seconds(5),
                statusFailureBackoffMultiplier: Int = 2,
                statusFailureBackoffMaxDelay: Duration = .seconds(60),
                capacityRetryBaseDelay: Duration = .milliseconds(500),
                capacityRetryJitterMaxDelay: Duration = .milliseconds(100),
                maxScopedStatusPathspecCount: Int = 128,
                lineDetailFreshnessInterval: Duration = .seconds(960),
                automaticDutyGapMultiplier: Int = 4,
                unchangedStatusCadenceMultipliers: [Int] = [1, 2, 4],
                minimumAutomaticStartInterval: Duration = .zero
            ) {
                precondition(activePaneCadence > .zero)
                precondition(visibleSidebarCadence >= activePaneCadence)
                precondition(openPaneCadence >= visibleSidebarCadence)
                precondition(backgroundCadence >= openPaneCadence)
                precondition(backgroundStripeCount > 0)
                precondition(maxConcurrentStatusComputes > 0)
                precondition(activePaneMaxConcurrent > 0)
                precondition(visibleSidebarMaxConcurrent > 0)
                precondition(openPaneMaxConcurrent > 0)
                precondition(backgroundMaxConcurrent > 0)
                precondition(visibleSidebarStripeSize > 0)
                precondition(suppressedWorktreeTombstoneLimit > 0)
                precondition(statusFailureBackoffBaseDelay > .zero)
                precondition(statusFailureBackoffMultiplier >= 1)
                precondition(statusFailureBackoffMaxDelay >= statusFailureBackoffBaseDelay)
                precondition(capacityRetryBaseDelay > .zero)
                precondition(capacityRetryJitterMaxDelay >= .zero)
                precondition(maxScopedStatusPathspecCount > 0)
                precondition(lineDetailFreshnessInterval > .zero)
                precondition(minimumAutomaticStartInterval >= .zero)
                precondition(automaticDutyGapMultiplier >= 1)
                precondition(unchangedStatusCadenceMultipliers.first == 1)
                precondition(
                    unchangedStatusCadenceMultipliers.elementsEqual(
                        unchangedStatusCadenceMultipliers.sorted()
                    )
                )

                self.activePaneCadence = activePaneCadence
                self.visibleSidebarCadence = visibleSidebarCadence
                self.openPaneCadence = openPaneCadence
                self.backgroundCadence = backgroundCadence
                self.backgroundStripeCount = backgroundStripeCount
                self.maxConcurrentStatusComputes = maxConcurrentStatusComputes
                self.activePaneMaxConcurrent = activePaneMaxConcurrent
                self.visibleSidebarMaxConcurrent = visibleSidebarMaxConcurrent
                self.openPaneMaxConcurrent = openPaneMaxConcurrent
                self.backgroundMaxConcurrent = backgroundMaxConcurrent
                self.visibleSidebarStripeSize = visibleSidebarStripeSize
                self.suppressedWorktreeTombstoneLimit = suppressedWorktreeTombstoneLimit
                self.statusFailureBackoffBaseDelay = statusFailureBackoffBaseDelay
                self.statusFailureBackoffMultiplier = statusFailureBackoffMultiplier
                self.statusFailureBackoffMaxDelay = statusFailureBackoffMaxDelay
                self.capacityRetryBaseDelay = capacityRetryBaseDelay
                self.capacityRetryJitterMaxDelay = capacityRetryJitterMaxDelay
                self.maxScopedStatusPathspecCount = maxScopedStatusPathspecCount
                self.lineDetailFreshnessInterval = lineDetailFreshnessInterval
                self.minimumAutomaticStartInterval = minimumAutomaticStartInterval
                self.automaticDutyGapMultiplier = automaticDutyGapMultiplier
                self.unchangedStatusCadenceMultipliers = unchangedStatusCadenceMultipliers
            }

            /// Exponential per-worktree backoff for status computes that time out
            /// `failureCount` is the number of consecutive failures (1 for the
            /// first). Each step multiplies by `statusFailureBackoffMultiplier`,
            /// clamped to `statusFailureBackoffMaxDelay`.
            package func statusFailureBackoffDelay(forConsecutiveFailureCount failureCount: Int) -> Duration {
                guard failureCount > 1 else {
                    return min(statusFailureBackoffBaseDelay, statusFailureBackoffMaxDelay)
                }
                var delay = statusFailureBackoffBaseDelay
                for _ in 1..<failureCount {
                    delay = Self.scaled(delay, by: statusFailureBackoffMultiplier)
                    if delay >= statusFailureBackoffMaxDelay {
                        return statusFailureBackoffMaxDelay
                    }
                }
                return min(delay, statusFailureBackoffMaxDelay)
            }

            package func capacityRetryDelay(for worktreeId: UUID) -> Duration {
                capacityRetryBaseDelay
                    + Self.jitterDelay(
                        maxDelay: capacityRetryJitterMaxDelay,
                        worktreeId: worktreeId
                    )
            }

            package func adaptiveCadence(
                base: Duration,
                unchangedResultCount: Int
            ) -> Duration {
                let index = min(max(unchangedResultCount, 0), unchangedStatusCadenceMultipliers.count - 1)
                return Self.scaled(base, by: unchangedStatusCadenceMultipliers[index])
            }

            package func automaticDutyGap(for completedDuty: Duration) -> Duration {
                Self.scaled(completedDuty, by: automaticDutyGapMultiplier)
            }

            package var maximumSettlementInterval: Duration {
                max(
                    adaptiveCadence(base: backgroundCadence, unchangedResultCount: .max),
                    max(lineDetailFreshnessInterval, statusFailureBackoffMaxDelay)
                )
            }

            package func backgroundRegistrationDelay(for worktreeId: UUID) -> Duration {
                registrationPhaseDelay(for: worktreeId, cadence: backgroundCadence)
            }

            package func registrationPhaseDelay(
                for worktreeId: UUID,
                cadence: Duration
            ) -> Duration {
                let stripe = backgroundStripe(for: worktreeId) + 1
                let cadenceNanoseconds = Self.nanoseconds(from: cadence)
                return .nanoseconds(cadenceNanoseconds * Int64(stripe) / Int64(backgroundStripeCount))
            }

            package func backgroundStripe(for worktreeId: UUID) -> Int {
                Int(Self.stableHash(for: worktreeId) % UInt64(backgroundStripeCount))
            }

            private static func scaled(_ duration: Duration, by multiplier: Int) -> Duration {
                var scaledDuration = Duration.zero
                for _ in 0..<multiplier {
                    scaledDuration += duration
                }
                return scaledDuration
            }

            private static func jitterDelay(maxDelay: Duration, worktreeId: UUID) -> Duration {
                let maxNanoseconds = nanoseconds(from: maxDelay)
                guard maxNanoseconds > 0 else { return .zero }
                let jitterNanoseconds = Int64(stableHash(for: worktreeId) % UInt64(maxNanoseconds + 1))
                return .nanoseconds(jitterNanoseconds)
            }

            private static func nanoseconds(from duration: Duration) -> Int64 {
                let components = duration.components
                let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
                guard seconds.overflow == false else { return seconds.partialValue }
                return seconds.partialValue + components.attoseconds / 1_000_000_000
            }

            private static func stableHash(for worktreeId: UUID) -> UInt64 {
                var hash: UInt64 = 14_695_981_039_346_656_037
                let prime: UInt64 = 1_099_511_628_211

                withUnsafeBytes(of: worktreeId.uuid) { bytes in
                    for byte in bytes {
                        hash ^= UInt64(byte)
                        hash &*= prime
                    }
                }

                return hash
            }
        }
    }

    package enum FilesystemIngress {
        package static let bufferedFineBatchCapacity: Int = 512
        package static let maximumRetainedOverflowPathsPerRegistration: Int = 256
        package static let maximumRetainedActivityOverflowParticipantScopes: Int = 256
    }

    package enum FilesystemSourceSync {
        /// Maximum number of worktree keys admitted to one sequential source-write batch.
        /// A full reconciliation retains every key and yields between batches.
        package static let maximumWorktreeKeysPerBatch: Int = 32
    }

    package enum RemoteReferenceRefresh {
        package static let automaticFreshnessFloor: Duration = .seconds(180)
        package static let automaticFailureRetryFloor: Duration = .seconds(180)
        package static let maximumConcurrentFetches: Int = 1
        package static let childProcessTimeoutSeconds: Double = 120
        package static let capacityRecheckDelay: Duration = .milliseconds(500)
    }

    package enum RepositoryFactDemand {
        package static let telemetryFlushInputCount: UInt64 = 64
    }

    package enum ForgeRefresh {
        package static let automaticFailureRetryFloor: Duration = .seconds(180)
        package static let maximumConcurrentProviderRequests: Int = 2
        package static let maximumBranchAliasesPerBatch: Int = 8
        package static let graphQLPageSize: Int = 25
        package static let maximumPagesPerBranch: Int = 4
        package static let providerTimeoutSeconds: Double = 8
        package static let capacityRecheckDelay: Duration = .milliseconds(500)
        package static let defaultPollingInterval: Duration = .seconds(45)
        package static let pendingFollowUpDelay: Duration = .seconds(1)
        package static let failureBackoffBaseDelay: Duration = .seconds(5)
        package static let failureBackoffMultiplier: Int = 2
        package static let failureBackoffMaxDelay: Duration = .seconds(60)

        package static func failureBackoffDelay(forConsecutiveFailureCount failureCount: Int) -> Duration {
            guard failureCount > 1 else {
                return min(failureBackoffBaseDelay, failureBackoffMaxDelay)
            }
            var backoffDelay = failureBackoffBaseDelay
            for _ in 1..<failureCount {
                var scaledDelay = Duration.zero
                for _ in 0..<failureBackoffMultiplier {
                    scaledDelay += backoffDelay
                }
                backoffDelay = scaledDelay
                if backoffDelay >= failureBackoffMaxDelay {
                    return failureBackoffMaxDelay
                }
            }
            return min(backoffDelay, failureBackoffMaxDelay)
        }
    }

    package enum Forge {
        /// Shared floor for automatic-refresh freshness and retries after a
        /// failed, truncated, or rate-limited pull request query.
        package static let automaticRefreshMinimumInterval: Duration = .seconds(180)
        /// Number of consecutive unsuccessful provider attempts (truncated,
        /// rate-limited, or failed) after which a repository's pull request
        /// state resolves to terminal-unavailable instead of staying pending
        /// forever. Bounded retries continue in the background at the normal
        /// backoff cadence; only the row's honesty signal changes.
        package static let consecutiveFailureHonestyThreshold: Int = 3
    }

    package enum WatchedFolderScanning {
        package static let maximumConcurrentTraversalQuanta: Int = 2
        package static let fallbackCadence: Duration = .seconds(300)
    }

    package enum ZmxStartup {
        package static let reconciliationTimeout: Duration = .seconds(3)
    }

    package enum StartupDiagnostic {
        package static let appActivationTimeout: Duration = .seconds(2)
        package static let launchRestoreBoundsTimeout: Duration = .seconds(3)
        package static let ipcTerminalSmokeReadinessTimeout: Duration = .seconds(10)
        package static let bridgeFileViewSmokeReadinessTimeout: Duration = .seconds(15)
        /// Review startup smoke covers pane mount, BridgeWeb intake-ready,
        /// native package load, metadata apply, projection, selected content,
        /// worker-pool readiness, and tree/click convergence. It is a heavier
        /// proof path than the IPC terminal and File View smokes.
        package static let bridgeReviewSmokeReadinessTimeout: Duration = .seconds(20)
    }

    package enum SidebarNavigation {
        package static let maximumNumberedDestinations: Int = 9
    }

    package enum SelectablePopover {
        package static let maxNumberedShortcuts: Int = 9
    }

    package enum PaneInbox {
        package static let maxVisibleNotifications: Int = 25
        package static let unreadBadgeDisplayLimit: Int = 9
    }

    package enum WorkspaceFocus {
        package enum Terminal {
            package static let stickyBottomBufferPx: CGFloat = 48
        }
    }

    package enum PaneZoomSplit {
        package static let defaultTerminalRatio: Double = 0.40
        package static let minimumTerminalRatio: Double = 0.30
        package static let maximumTerminalRatio: Double = 0.60

        package static func containsTerminalRatio(_ ratio: Double) -> Bool {
            ratio.isFinite && ratio >= minimumTerminalRatio && ratio <= maximumTerminalRatio
        }

        package static func clampTerminalRatio(_ ratio: Double) -> Double {
            guard ratio.isFinite else { return defaultTerminalRatio }
            return min(max(ratio, minimumTerminalRatio), maximumTerminalRatio)
        }
    }

    package enum InboxNotification {
        /// Maximum number of notifications retained in the inbox per workspace.
        /// When `append` would exceed this cap, the oldest entry is evicted.
        package static let maxRetained: Int = 1000
        package static let maxTitleCharacters: Int = 200
        package static let maxBodyCharacters: Int = 8000
        package static let maxRPCPostsPerWindow: Int = 20
        package static let rpcPostRateLimitWindowSeconds: TimeInterval = 60

        /// Minimum command duration before a command-finished event
        /// is promoted into inbox history.
        package static let commandFinishedMinDurationNanoseconds: UInt64 = 10_000_000_000
        /// Durations beyond one week are treated as corrupt runtime payloads.
        package static let commandFinishedMaxTrustedDurationNanoseconds: UInt64 = 604_800_000_000_000
        package static let terminalActivityOutputBurstThresholdRows: Int = 30
        package static let terminalActivityQuietDebounceDuration: Duration = .milliseconds(750)
        package static let agentSettledMinimumRows: Int = 100
        package static let agentSettledHighConfidenceRows: Int = 500
        package static let agentSettledMinimumCandidateDuration: Duration = .seconds(60)
        package static let agentSettledMinimumActiveDuration: Duration = .seconds(360)
        package static let agentSettledQuietDuration: Duration = .seconds(180)
        package static let terminalActivitySessionIdleTimeoutDuration: Duration = .seconds(300)
        /// Minimum publication interval for a pane's activity-status fact (sidebar L2 text).
        /// A distinct settle inside the window is retained as the pane's latest pending value and
        /// published at the deadline without requiring another settle.
        package static let paneActivityStatusMinimumPublishInterval: Duration = .seconds(10)
    }

    /// Drag-and-drop behavioral rules. These are decisions about HOW the
    /// drag system works, not how it looks. Visual constants (marker
    /// width, opacity, animation) live in `AppStyles`.
    package enum DragAndDrop {
        /// Cursor zone partition for a pane in a row: each side gets
        /// this fraction of the pane width, the center keeps the rest.
        ///
        ///     ┌──────┬─────────────────────┬──────┐
        ///     │ 1/4  │        1/2          │ 1/4  │
        ///     │ left │       center        │ right│
        ///     └──────┴─────────────────────┴──────┘
        ///
        /// Side zones resolve to slot targets (between/edge insert);
        /// the center zone resolves to a split target.
        package static let paneRowSideZoneFraction: CGFloat = 0.25

        /// Side-zone hittability floor in points. On narrow panes the
        /// natural side fraction collapses below this; the side zones
        /// grow to this floor and the center zone shrinks (or
        /// disappears when the pane can't host all three zones).
        package static let paneRowSideZoneFloor: CGFloat = 24

        /// Drawer new-row creation band — fraction of drawer panel
        /// height for the top/bottom drop zones that create a new row.
        /// Only applies to single-row drawers (two-row is at max).
        package static let drawerNewRowBandRatio: CGFloat = 0.2

        /// Floor for the drawer new-row creation band height. On short
        /// drawers the ratio drops below this; the band stays at this
        /// minimum height.
        package static let drawerNewRowBandMinHeight: CGFloat = 28

        /// Drawer hard cap on number of stacked rows. The drawer never
        /// exceeds this; new-row band targets are unavailable when the
        /// drawer is at this row count.
        package static let drawerMaxRows: Int = 2

        /// Minimum pane size after a split or resize. Splits that would
        /// produce a child smaller than this are forbidden.
        package static let splitMinimumPaneSize: CGFloat = 10
    }
}

package enum StartupDeferralOutcome: String, Equatable, Sendable {
    case completed
    case cancelled
    case fallbackTimeout = "fallback_timeout"
}
