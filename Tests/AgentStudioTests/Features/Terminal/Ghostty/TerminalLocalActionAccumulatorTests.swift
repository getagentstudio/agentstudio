import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("Terminal local action accumulator")
struct TerminalLocalActionAccumulatorTests {
    @Test("failed title apply stays pending without self-rescheduling")
    func failedTitleApplyStaysPendingWithoutSelfRescheduling() throws {
        let recorder = DrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: recorder.record,
            scheduleFollowUpDrain: recorder.record
        )
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("unavailable"), for: surfaceID) == .scheduled)
        var drainAttemptCount = 0
        for _ in 0..<3 {
            guard let failedBatch = accumulator.beginDrain(for: surfaceID, lane: .title) else { break }
            drainAttemptCount += 1
            accumulator.restoreUnacknowledgedPublications(from: failedBatch)
            #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
        }

        #expect(drainAttemptCount == 1)
        #expect(recorder.requests.count == 1)
        #expect(accumulator.hasPendingActions(for: surfaceID))
    }

    @Test("committed equal title does not create a second scheduler claim")
    func committedEqualTitleDoesNotCreateSecondSchedulerClaim() throws {
        let recorder = DrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: recorder.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
        let appliedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        accumulator.acknowledgeSuccessfulTitlePublication(
            try #require(appliedBatch.titleMetadata),
            for: surfaceID
        )
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)

        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .equalSuppressed)
        #expect(recorder.requests.count == 1)
        #expect(accumulator.offer(.titleChanged("B"), for: surfaceID) == .scheduled)
        #expect(recorder.requests.count == 2)
    }

    @Test("first title admission fixes one absolute one-second deadline through replacement")
    func firstTitleAdmissionFixesAbsoluteDeadlineThroughReplacement() throws {
        let recorder = DrainRequestRecorder()
        let clock = MutableNanosecondClock(initialValue: 7)
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: recorder.record,
            nowNanoseconds: clock.now
        )
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("first"), for: surfaceID) == .scheduled)
        clock.set(99)
        #expect(accumulator.offer(.tabTitleChanged("latest"), for: surfaceID) == .coalesced)

        #expect(
            recorder.requests == [
                .init(
                    surfaceID: surfaceID,
                    request: .init(
                        lane: .title,
                        absoluteDeadlineNanoseconds: 1_000_000_007
                    )
                )
            ]
        )
        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        #expect(batch.titleMetadata?.runtimeTitle == .tabTitleChanged("latest"))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
    }

    @Test("title admitted during a title drain receives its own fixed follow-up deadline")
    func titleAdmittedDuringTitleDrainReceivesOwnFixedFollowUpDeadline() throws {
        let recorder = DrainRequestRecorder()
        let clock = MutableNanosecondClock(initialValue: 10)
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: recorder.record,
            scheduleFollowUpDrain: recorder.record,
            nowNanoseconds: clock.now
        )
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.titleChanged("first"), for: surfaceID)
        _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        clock.set(20)
        accumulator.offer(.titleChanged("follow-up"), for: surfaceID)

        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .followUpScheduled)
        #expect(
            recorder.requests.map(\.request.absoluteDeadlineNanoseconds) == [
                1_000_000_010,
                1_000_000_020,
            ]
        )
    }

    @Test("immediate drain leaves the independent pending title lane untouched")
    func immediateDrainLeavesPendingTitleLaneUntouched() throws {
        let recorder = DrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: recorder.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.titleChanged("title"), for: surfaceID)
        accumulator.offer(.mouseShape(.text), for: surfaceID)

        let immediateBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(immediateBatch.presentation.mouseShape == .text)
        #expect(immediateBatch.titleMetadata == nil)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)

        let titleBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        #expect(titleBatch.presentation.mouseShape == nil)
        #expect(titleBatch.titleMetadata?.runtimeTitle == .titleChanged("title"))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
    }

    @Test("exact title barrier preserves independently pending immediate work")
    func exactTitleBarrierPreservesIndependentlyPendingImmediateWork() throws {
        let recorder = DrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: recorder.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.titleChanged("title"), for: surfaceID)
        accumulator.offer(.mouseVisibility(false), for: surfaceID)

        let barrier = try #require(accumulator.detachTitleBeforeExactBarrier(for: surfaceID))
        #expect(barrier.metadata.runtimeTitle == .titleChanged("title"))
        let immediateBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(immediateBatch.presentation.mouseVisibility == false)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
    }

    @Test("title-only offers request one title-window drain")
    func titleOnlyOffersRequestOneTitleWindowDrain() {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("first"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.titleChanged("second"), for: surfaceID) == .coalesced)
        #expect(accumulator.offer(.tabTitleChanged("third"), for: surfaceID) == .coalesced)

        #expect(scheduler.recordedSchedules == [.init(surfaceID: surfaceID, schedule: .titleDeadline)])
    }

    @Test("presentation activity and search offers request immediate drains")
    func nonTitleOffersRequestImmediateDrains() {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let presentationSurfaceID = UUIDv7.generate()
        let activitySurfaceID = UUIDv7.generate()
        let searchSurfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.mouseShape(.text), for: presentationSurfaceID) == .scheduled)
        #expect(
            accumulator.offer(
                .scrollbar(
                    ScrollbarState(top: 80, bottom: 100, total: 100),
                    observedAtMilliseconds: 1
                ),
                for: activitySurfaceID
            ) == .scheduled
        )
        #expect(accumulator.offer(.searchStarted(query: "needle"), for: searchSurfaceID) == .scheduled)

        #expect(
            scheduler.recordedSchedules == [
                .init(surfaceID: presentationSurfaceID, schedule: .immediate),
                .init(surfaceID: activitySurfaceID, schedule: .immediate),
                .init(surfaceID: searchSurfaceID, schedule: .immediate),
            ]
        )
    }

    @Test("immediate work schedules its own lane without replacing the title claim")
    func immediateWorkSchedulesOwnLaneWithoutReplacingTitleClaim() {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("title"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.mouseShape(.text), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.searchStarted(query: "needle"), for: surfaceID) == .coalesced)

        #expect(
            scheduler.recordedSchedules == [
                .init(surfaceID: surfaceID, schedule: .titleDeadline),
                .init(surfaceID: surfaceID, schedule: .immediate),
            ]
        )
    }

    @Test("title work schedules its own lane without replacing the immediate claim")
    func titleWorkSchedulesOwnLaneWithoutReplacingImmediateClaim() {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.mouseVisibility(false), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.titleChanged("title"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.tabTitleChanged("tab"), for: surfaceID) == .coalesced)

        #expect(
            scheduler.recordedSchedules == [
                .init(surfaceID: surfaceID, schedule: .immediate),
                .init(surfaceID: surfaceID, schedule: .titleDeadline),
            ]
        )
    }

    @Test("follow-up drain schedule reflects the pending action class")
    func followUpDrainScheduleReflectsPendingActionClass() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let titleOnlySurfaceID = UUIDv7.generate()
        let mixedSurfaceID = UUIDv7.generate()
        let nonTitleSurfaceID = UUIDv7.generate()

        accumulator.offer(.titleChanged("initial"), for: titleOnlySurfaceID)
        _ = try #require(accumulator.beginDrain(for: titleOnlySurfaceID, lane: .title))
        accumulator.offer(.tabTitleChanged("follow-up"), for: titleOnlySurfaceID)
        #expect(accumulator.finishDrain(for: titleOnlySurfaceID, lane: .title) == .followUpScheduled)

        accumulator.offer(.titleChanged("initial"), for: mixedSurfaceID)
        _ = try #require(accumulator.beginDrain(for: mixedSurfaceID, lane: .title))
        accumulator.offer(.titleChanged("follow-up"), for: mixedSurfaceID)
        accumulator.offer(.mouseShape(.pointer), for: mixedSurfaceID)
        #expect(accumulator.finishDrain(for: mixedSurfaceID, lane: .title) == .followUpScheduled)

        accumulator.offer(.mouseShape(.text), for: nonTitleSurfaceID)
        _ = try #require(accumulator.beginDrain(for: nonTitleSurfaceID, lane: .immediate))
        accumulator.offer(.mouseVisibility(false), for: nonTitleSurfaceID)
        #expect(accumulator.finishDrain(for: nonTitleSurfaceID, lane: .immediate) == .followUpScheduled)

        #expect(
            scheduler.recordedSchedules == [
                .init(surfaceID: titleOnlySurfaceID, schedule: .titleDeadline),
                .init(surfaceID: titleOnlySurfaceID, schedule: .titleDeadline),
                .init(surfaceID: mixedSurfaceID, schedule: .titleDeadline),
                .init(surfaceID: mixedSurfaceID, schedule: .immediate),
                .init(surfaceID: mixedSurfaceID, schedule: .titleDeadline),
                .init(surfaceID: nonTitleSurfaceID, schedule: .immediate),
                .init(surfaceID: nonTitleSurfaceID, schedule: .immediate),
            ]
        )
    }

    @Test("title callbacks retain independent latest runtime and surface values")
    func titleCallbacksRetainIndependentLatestValues() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("window"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.tabTitleChanged("tab"), for: surfaceID) == .coalesced)

        #expect(scheduler.scheduledSurfaceIDs == [surfaceID])
        #expect(accumulator.hasPendingActions(for: surfaceID))
        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        #expect(batch.titleMetadata?.runtimeTitle == .tabTitleChanged("tab"))
        #expect(batch.titleMetadata?.surfaceTitle == "window")
        #expect(batch.metrics.offeredCount == 2)
        #expect(batch.metrics.replacedCount == 1)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
        #expect(!accumulator.hasPendingActions(for: surfaceID))
        #expect(accumulator.retainedEntryCount == 0)

        let tabOnlySurfaceID = UUIDv7.generate()
        accumulator.offer(.tabTitleChanged("tab-only"), for: tabOnlySurfaceID)
        let tabOnlyBatch = try #require(accumulator.beginDrain(for: tabOnlySurfaceID, lane: .title))
        #expect(tabOnlyBatch.titleMetadata?.runtimeTitle == .tabTitleChanged("tab-only"))
        #expect(tabOnlyBatch.titleMetadata?.surfaceTitle == nil)
    }

    @Test("exact title barriers report only exact title accounting and no extra MainActor task")
    func exactTitleBarrierAccountingIsHonest() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.mouseShape(.text), for: surfaceID)
        accumulator.offer(.titleChanged("A"), for: surfaceID)
        accumulator.offer(.titleChanged("A"), for: surfaceID)
        accumulator.offer(.tabTitleChanged("C"), for: surfaceID)

        let barrier = try #require(accumulator.detachTitleBeforeExactBarrier(for: surfaceID))
        #expect(barrier.metadata.runtimeTitle == .tabTitleChanged("C"))
        #expect(barrier.metadata.surfaceTitle == "A")
        #expect(barrier.metrics.offeredCount == 3)
        #expect(barrier.metrics.replacedCount == 1)
        #expect(barrier.metrics.equalSuppressedCount == 1)
        #expect(barrier.metrics.scheduledDrainCount == 1)
        #expect(barrier.metrics.followUpDrainCount == 0)
        let performanceSnapshot = Ghostty.ActionRouter.terminalAccumulatorDrainPerformanceSnapshot(for: barrier)
        #expect(
            performanceSnapshot
                == TerminalAccumulatorDrainPerformanceSnapshot(
                    drainClass: .exactBarrier,
                    offeredCount: 3,
                    replacedCount: 1,
                    equalSuppressedCount: 1,
                    scheduledDrainCount: 1,
                    followUpDrainCount: 0,
                    mainActorTaskCount: 0,
                    activityAggregateCount: 0,
                    retainedEntryCount: 2,
                    retainedSizeBytes: 128
                )
        )
        #expect(
            Ghostty.ActionRouter.terminalAccumulatorQueueAge(
                firstOfferedAtNanoseconds: barrier.firstOfferedAtNanoseconds,
                currentUptimeNanoseconds: barrier.firstOfferedAtNanoseconds + 50
            ) == .nanoseconds(50)
        )

        let remainingBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(remainingBatch.presentation.mouseShape == .text)
        #expect(remainingBatch.titleMetadata == nil)
        #expect(remainingBatch.metrics.offeredCount == 1)
        #expect(remainingBatch.metrics.replacedCount == 0)
        #expect(remainingBatch.metrics.equalSuppressedCount == 0)
        #expect(remainingBatch.metrics.scheduledDrainCount == 1)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
    }

    @Test("metric subtraction rejects values outside the pending batch")
    func metricSubtractionRequiresSubset() {
        let pendingMetrics = TerminalLocalAccumulatorMetrics(
            offeredCount: 2,
            replacedCount: 1,
            equalSuppressedCount: 0,
            scheduledDrainCount: 1,
            followUpDrainCount: 0
        )
        let invalidTitleMetrics = TerminalLocalAccumulatorMetrics(
            offeredCount: 3,
            replacedCount: 1,
            equalSuppressedCount: 0,
            scheduledDrainCount: 1,
            followUpDrainCount: 0
        )

        #expect(pendingMetrics.subtracting(invalidTitleMetrics) == nil)
    }

    @Test("exact title barriers leave mixed follow-up scheduling metrics with the remaining batch")
    func exactTitleBarrierPreservesMixedFollowUpMetrics() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.mouseShape(.text), for: surfaceID)
        _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        accumulator.offer(.titleChanged("A"), for: surfaceID)
        accumulator.offer(.mouseVisibility(true), for: surfaceID)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .followUpScheduled)

        let barrier = try #require(accumulator.detachTitleBeforeExactBarrier(for: surfaceID))
        #expect(barrier.metrics.followUpDrainCount == 0)

        let remainingBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(remainingBatch.presentation.mouseVisibility == true)
        #expect(remainingBatch.titleMetadata == nil)
        #expect(remainingBatch.metrics.followUpDrainCount == 1)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
    }

    @Test("large title burst schedules one bounded drain and retains the latest kind")
    func largeTitleBurstIsBounded() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        for index in 0..<100_000 {
            if index.isMultiple(of: 2) {
                accumulator.offer(.titleChanged("window-\(index)"), for: surfaceID)
            } else {
                accumulator.offer(.tabTitleChanged("tab-\(index)"), for: surfaceID)
            }
        }

        #expect(scheduler.scheduledSurfaceIDs == [surfaceID])
        #expect(accumulator.retainedEntryCount <= TerminalLocalActionAccumulator.maximumRetainedEntriesPerSurface)
        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        #expect(Ghostty.ActionRouter.terminalAccumulatorDrainClass(for: batch) == .titleDeadline)
        #expect(batch.titleMetadata?.runtimeTitle == .tabTitleChanged("tab-99999"))
        #expect(batch.titleMetadata?.surfaceTitle == "window-99998")
        #expect(batch.metrics.offeredCount == 100_000)
        #expect(batch.metrics.replacedCount == 99_999)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
    }

    @Test("one hundred thousand samples retain fixed state and preserve sufficient statistics")
    func largeBurstIsBounded() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceIDs = (0..<10).map { _ in UUIDv7.generate() }

        for sampleIndex in 0..<100_000 {
            let surfaceIndex = sampleIndex % surfaceIDs.count
            let perSurfaceIndex = sampleIndex / surfaceIDs.count
            let total = 1000 + perSurfaceIndex
            accumulator.offer(
                .scrollbar(
                    ScrollbarState(top: total - 20, bottom: total, total: total),
                    observedAtMilliseconds: Int64(sampleIndex)
                ),
                for: surfaceIDs[surfaceIndex]
            )
            accumulator.offer(.mouseVisibility(sampleIndex.isMultiple(of: 2)), for: surfaceIDs[surfaceIndex])
        }

        #expect(scheduler.scheduledSurfaceIDs.count == surfaceIDs.count)
        #expect(accumulator.pendingSurfaceCount == surfaceIDs.count)
        #expect(
            accumulator.retainedEntryCount <= surfaceIDs.count
                * TerminalLocalActionAccumulator.maximumRetainedEntriesPerSurface)

        for (surfaceIndex, surfaceID) in surfaceIDs.enumerated() {
            let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
            let expectedLatestTotal = 1000 + ((99_990 + surfaceIndex) / surfaceIDs.count)
            #expect(batch.presentation.scrollbarState?.total == expectedLatestTotal)
            #expect(batch.activity?.sampleCount == 10_000)
            #expect(batch.activity?.cumulativePositiveRowGrowth == 9999)
            #expect(batch.activity?.firstTotalRows == 1000)
            #expect(batch.activity?.latestTotalRows == expectedLatestTotal)
            #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        }

        #expect(accumulator.pendingSurfaceCount == 0)
        #expect(accumulator.retainedEntryCount == 0)
    }

    @Test("growth before decreases and pinned edges survive coalescing")
    func sufficientStatisticsSurviveReset() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()
        let samples = [
            ScrollbarState(top: 90, bottom: 100, total: 100),
            ScrollbarState(top: 100, bottom: 110, total: 110),
            ScrollbarState(top: 50, bottom: 60, total: 100),
            ScrollbarState(top: 95, bottom: 105, total: 105),
        ]

        for (index, state) in samples.enumerated() {
            accumulator.offer(.scrollbar(state, observedAtMilliseconds: Int64(index + 10)), for: surfaceID)
        }

        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(batch.metrics.outputAdvancementCount == 2)
        #expect(Ghostty.ActionRouter.terminalAccumulatorDrainClass(for: batch) == .immediate)
        let activity = try #require(batch.activity)
        #expect(activity.cumulativePositiveRowGrowth == 15)
        #expect(activity.firstObservedAtMilliseconds == 10)
        #expect(activity.latestObservedAtMilliseconds == 13)
        #expect(activity.didExitPinnedToBottom)
        #expect(activity.didEnterPinnedToBottom)
        #expect(activity.latestIsPinnedToBottom)
    }

    @Test("offers during a drain create exactly one convergent follow-up")
    func oneFollowUpDrain() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.mouseShape(.text), for: surfaceID)
        _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        accumulator.offer(.mouseShape(.pointer), for: surfaceID)
        accumulator.offer(.mouseVisibility(false), for: surfaceID)

        #expect(scheduler.scheduledSurfaceIDs == [surfaceID])
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .followUpScheduled)
        #expect(scheduler.scheduledSurfaceIDs == [surfaceID, surfaceID])

        let followUp = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(followUp.presentation.mouseShape == .pointer)
        #expect(followUp.presentation.mouseVisibility == false)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        #expect(scheduler.scheduledSurfaceIDs == [surfaceID, surfaceID])
    }

    @Test("search lifecycle barriers reject late values after end")
    func searchBarrierRejectsLateValues() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.searchStarted(query: "needle"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.searchMatches(7), for: surfaceID) == .coalesced)
        #expect(accumulator.offer(.searchSelection(2), for: surfaceID) == .coalesced)
        #expect(accumulator.offer(.searchEnded, for: surfaceID) == .coalesced)
        #expect(accumulator.offer(.searchMatches(99), for: surfaceID) == .rejectedInactiveSearch)
        #expect(accumulator.offer(.searchSelection(98), for: surfaceID) == .rejectedInactiveSearch)

        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(batch.searchLifecycle?.firstEpoch == 1)
        #expect(batch.searchLifecycle?.latestEpoch == 1)
        #expect(batch.searchLifecycle?.transitionCount == 2)
        #expect(batch.searchLifecycle?.state == .inactive(lastEndedEpoch: 1))
        #expect(batch.presentation.searchUpdate == nil)
    }

    @Test("search lifecycle churn retains one fixed summary")
    func searchLifecycleChurnIsBounded() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        for index in 0..<100_000 {
            if index.isMultiple(of: 2) {
                accumulator.offer(.searchStarted(query: "query-\(index)"), for: surfaceID)
            } else {
                accumulator.offer(.searchEnded, for: surfaceID)
            }
        }

        #expect(accumulator.retainedEntryCount == 1)
        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(batch.searchLifecycle?.transitionCount == 100_000)
        #expect(batch.searchLifecycle?.state == .inactive(lastEndedEpoch: 50_000))
    }

    @Test("search end after an earlier drain reports one barrier")
    func searchEndAcrossDrainsIsTruthful() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.searchStarted(query: "needle"), for: surfaceID)
        let startedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(startedBatch.searchLifecycle?.transitionCount == 1)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)

        #expect(accumulator.offer(.searchEnded, for: surfaceID) == .scheduled)
        let endedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(endedBatch.searchLifecycle?.transitionCount == 1)
        #expect(endedBatch.searchLifecycle?.state == .inactive(lastEndedEpoch: 1))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        #expect(accumulator.retainedEntryCount == 0)
    }

    @Test("search epochs remain monotonic across fully drained sessions")
    func searchEpochsRemainMonotonicAcrossFullyDrainedSessions() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.searchStarted(query: "first"), for: surfaceID)
        let firstStartedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(firstStartedBatch.searchLifecycle?.state == .active(query: "first", epoch: 1))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)

        accumulator.offer(.searchEnded, for: surfaceID)
        let firstEndedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(firstEndedBatch.searchLifecycle?.state == .inactive(lastEndedEpoch: 1))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        #expect(accumulator.pendingSurfaceCount == 0)
        #expect(accumulator.retainedEntryCount == 0)

        accumulator.offer(.searchStarted(query: "second"), for: surfaceID)
        let secondStartedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))

        #expect(secondStartedBatch.searchLifecycle?.state == .active(query: "second", epoch: 2))
    }

    @Test("title barrier eviction preserves the search epoch")
    func titleBarrierEvictionPreservesSearchEpoch() throws {
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let surfaceID = UUIDv7.generate()

        accumulator.offer(.searchStarted(query: "first"), for: surfaceID)
        _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        accumulator.offer(.searchEnded, for: surfaceID)
        _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)

        accumulator.offer(.titleChanged("after search"), for: surfaceID)
        _ = try #require(accumulator.detachTitleBeforeExactBarrier(for: surfaceID))

        accumulator.offer(.searchStarted(query: "second"), for: surfaceID)
        let secondStartedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))

        #expect(secondStartedBatch.searchLifecycle?.state == .active(query: "second", epoch: 2))
    }

    @Test("surface removal resets only that surface search epoch")
    func surfaceRemovalResetsOnlyThatSurfaceSearchEpoch() throws {
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let removedSurfaceID = UUIDv7.generate()
        let closedSurfaceID = UUIDv7.generate()
        let retainedSurfaceID = UUIDv7.generate()

        for surfaceID in [removedSurfaceID, closedSurfaceID, retainedSurfaceID] {
            accumulator.offer(.searchStarted(query: "first"), for: surfaceID)
            _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
            #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
            accumulator.offer(.searchEnded, for: surfaceID)
            _ = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
            #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        }

        accumulator.removeSurface(removedSurfaceID)
        #expect(
            accumulator.detachActivityForSurfaceClose(
                closedSurfaceID,
                defaultActivityContext: nil
            ) == nil
        )
        accumulator.offer(.searchStarted(query: "replacement"), for: removedSurfaceID)
        accumulator.offer(.searchStarted(query: "closed replacement"), for: closedSurfaceID)
        accumulator.offer(.searchStarted(query: "retained"), for: retainedSurfaceID)

        let replacementBatch = try #require(accumulator.beginDrain(for: removedSurfaceID, lane: .immediate))
        let closedReplacementBatch = try #require(accumulator.beginDrain(for: closedSurfaceID, lane: .immediate))
        let retainedBatch = try #require(accumulator.beginDrain(for: retainedSurfaceID, lane: .immediate))
        #expect(replacementBatch.searchLifecycle?.state == .active(query: "replacement", epoch: 1))
        #expect(closedReplacementBatch.searchLifecycle?.state == .active(query: "closed replacement", epoch: 1))
        #expect(retainedBatch.searchLifecycle?.state == .active(query: "retained", epoch: 2))
    }

    @Test("concurrent offers are linearized without retained debt")
    func concurrentOffersAreLinearized() async throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let surfaceID = UUIDv7.generate()

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<20 {
                group.addTask {
                    for sample in 0..<5000 {
                        accumulator.offer(
                            .mouseShape(.other(rawValue: UInt32(worker * 5000 + sample))), for: surfaceID)
                    }
                }
            }
        }

        #expect(scheduler.scheduledSurfaceIDs == [surfaceID])
        let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        #expect(batch.metrics.offeredCount == 100_000)
        #expect(batch.metrics.replacedCount == 99_999)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        #expect(accumulator.retainedEntryCount == 0)
    }

    @Test("cleanup removes only the matching surface lifetime")
    func cleanupIsLifetimeScoped() throws {
        let scheduler = DrainScheduleRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: scheduler.record)
        let oldSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()

        accumulator.offer(.mouseShape(.text), for: oldSurfaceID)
        accumulator.offer(.mouseShape(.pointer), for: replacementSurfaceID)
        accumulator.removeSurface(oldSurfaceID)
        #expect(accumulator.offer(.searchMatches(7), for: oldSurfaceID) == .rejectedInactiveSearch)

        #expect(accumulator.beginDrain(for: oldSurfaceID, lane: .immediate) == nil)
        #expect(accumulator.retainedEntryCount == 1)
        let replacement = try #require(accumulator.beginDrain(for: replacementSurfaceID, lane: .immediate))
        #expect(replacement.presentation.mouseShape == .pointer)

        accumulator.offer(.titleChanged("stale"), for: oldSurfaceID)
        accumulator.removeSurface(oldSurfaceID)
        #expect(accumulator.beginDrain(for: oldSurfaceID, lane: .immediate) == nil)
    }

    @Test("context transition detaches earlier evidence from later samples")
    func contextTransitionSeparatesActivityEpochs() throws {
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let surfaceID = UUIDv7.generate()
        let before = TerminalActivityProjectionContext(
            isAttended: false,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )
        let after = TerminalActivityProjectionContext(
            isAttended: true,
            isAgentClassified: true,
            outputBurstThreshold: 30
        )
        accumulator.offer(
            .scrollbar(ScrollbarState(top: 60, bottom: 100, total: 100), observedAtMilliseconds: 1000),
            for: surfaceID
        )

        let detached = try #require(
            accumulator.detachActivityBeforeControl(
                for: surfaceID,
                contextBeforeControl: before,
                contextAfterControl: after
            )
        )
        accumulator.offer(
            .scrollbar(ScrollbarState(top: 80, bottom: 120, total: 120), observedAtMilliseconds: 1100),
            for: surfaceID
        )
        let laterBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))

        #expect(detached.context == before)
        #expect(detached.latestState.total == 100)
        #expect(laterBatch.activityContext == after)
        #expect(laterBatch.activity?.latestTotalRows == 120)
    }
}

private final class MutableNanosecondClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(initialValue: UInt64) {
        value = initialValue
    }

    func now() -> UInt64 {
        lock.withLock { value }
    }

    func set(_ value: UInt64) {
        lock.withLock {
            self.value = value
        }
    }
}

private final class DrainRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedDrainRequest] = []

    var requests: [RecordedDrainRequest] {
        lock.withLock { storage }
    }

    func record(_ surfaceID: UUID, _ request: TerminalLocalDrainRequest, _: TerminalLocalActionAccumulator) {
        lock.withLock {
            storage.append(.init(surfaceID: surfaceID, request: request))
        }
    }
}

private struct RecordedDrainRequest: Equatable {
    let surfaceID: UUID
    let request: TerminalLocalDrainRequest
}

private enum TerminalLocalDrainSchedule: Equatable {
    case immediate
    case titleDeadline
}

private final class DrainScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedDrainSchedule] = []

    var recordedSchedules: [RecordedDrainSchedule] {
        lock.withLock { storage }
    }

    var scheduledSurfaceIDs: [UUID] {
        lock.withLock { storage.map(\.surfaceID) }
    }

    func record(_ surfaceID: UUID, _ request: TerminalLocalDrainRequest, _: TerminalLocalActionAccumulator) {
        lock.withLock {
            storage.append(
                .init(
                    surfaceID: surfaceID,
                    schedule: request.lane == .immediate ? .immediate : .titleDeadline
                )
            )
        }
    }
}

private struct RecordedDrainSchedule: Equatable {
    let surfaceID: UUID
    let schedule: TerminalLocalDrainSchedule
}
