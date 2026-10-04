import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AppKit
import Foundation
import Observation
import Synchronization

struct SidebarPerformanceProofTabReadback: Equatable, Sendable {
    let orderedTabIDs: [UUID]
    let activeTabID: UUID?
    let activePaneID: UUID?
    let activePaneIDByTabID: [UUID: UUID]
    let nativeActiveTabIsVisible: Bool
    let nativeActivePaneIsVisible: Bool
    let nativeActivePaneHasFocus: Bool
}

struct SidebarPerformanceProofShellReadback: Equatable, Sendable {
    let semanticSidebarIsCollapsed: Bool
    let nativeSidebarIsCollapsed: Bool
    let nativeSidebarGeometryIsVisible: Bool
    let nativeFilterValue: String?
    let nativeSelectedGroupingMode: RepoExplorerGroupingMode?
    let nativeSidebarAccessibilityIsReady: Bool
    let nativePresentedRowCount: Int?
    let nativeVisibleProjection: RepoExplorerNativeVisibleProjectionReadback?
    let tab: SidebarPerformanceProofTabReadback
}

#if DEBUG
    struct SidebarPerformanceProofReadback: Equatable, Sendable {
        let repoExplorer: RepoExplorerPerformanceProofReadback
        let shell: SidebarPerformanceProofShellReadback
        let windowAttendance: SidebarPerformanceProofWindowAttendance
    }

    enum SidebarPerformanceProofExpectedOutcome: Equatable, Sendable {
        case search(query: String)
        case grouping(RepoExplorerGroupingMode)
        case sidebarCollapsed(Bool)
        case tabSelection(tabID: UUID, paneID: UUID)
    }

    struct SidebarPerformanceProofOutstandingAction: Sendable {
        let sequence: Int
        let baseline: SidebarPerformanceProofReadback
        let expectedOutcome: SidebarPerformanceProofExpectedOutcome
    }

    @MainActor
    struct SidebarPerformanceProofActionTracker {
        private(set) var outstandingAction: SidebarPerformanceProofOutstandingAction?

        mutating func begin(
            sequence: Int,
            baseline: SidebarPerformanceProofReadback,
            expectedOutcome: SidebarPerformanceProofExpectedOutcome
        ) -> SidebarPerformanceProofOutstandingAction? {
            guard outstandingAction == nil else { return nil }
            let action = SidebarPerformanceProofOutstandingAction(
                sequence: sequence,
                baseline: baseline,
                expectedOutcome: expectedOutcome
            )
            outstandingAction = action
            return action
        }

        mutating func advance(
            sequence: Int,
            baseline: SidebarPerformanceProofReadback,
            expectedOutcome: SidebarPerformanceProofExpectedOutcome
        ) -> SidebarPerformanceProofOutstandingAction? {
            guard outstandingAction?.sequence == sequence else { return nil }
            let action = SidebarPerformanceProofOutstandingAction(
                sequence: sequence,
                baseline: baseline,
                expectedOutcome: expectedOutcome
            )
            outstandingAction = action
            return action
        }

        mutating func complete(sequence: Int) -> Bool {
            guard outstandingAction?.sequence == sequence else { return false }
            outstandingAction = nil
            return true
        }

        nonisolated static func matches(
            _ readback: SidebarPerformanceProofReadback,
            action: SidebarPerformanceProofOutstandingAction
        ) -> Bool {
            let repoExplorer = readback.repoExplorer
            let shell = readback.shell
            switch action.expectedOutcome {
            case .search(let query):
                return projectionAdvanced(from: action.baseline.repoExplorer, to: repoExplorer)
                    && repoExplorer.query == query
                    && shell.nativeFilterValue == query
                    && repoExplorer.focusDisposition == .filterFocused
                    && visibleSidebarIsSettled(readback)
            case .grouping(let groupingMode):
                return projectionAdvanced(from: action.baseline.repoExplorer, to: repoExplorer)
                    && repoExplorer.groupingMode == groupingMode
                    && shell.nativeSelectedGroupingMode == groupingMode
                    && visibleSidebarIsSettled(readback)
            case .sidebarCollapsed(let isCollapsed):
                return shell.semanticSidebarIsCollapsed == isCollapsed
                    && shell.nativeSidebarIsCollapsed == isCollapsed
                    && shell.nativeSidebarGeometryIsVisible == !isCollapsed
                    && repoExplorer.isDemanded == !isCollapsed
                    && repoExplorer.presentationIsReady == !isCollapsed
                    && shell.nativeSidebarAccessibilityIsReady == !isCollapsed
                    && (isCollapsed || shell.nativePresentedRowCount == repoExplorer.representedRowCount)
                    && (isCollapsed || nativeVisibleProjectionMatches(readback))
                    && shell.tab.nativeActivePaneHasFocus
                    && readback.windowAttendance.isAttended
            case .tabSelection(let tabID, let paneID):
                return shell.tab.activeTabID == tabID
                    && shell.tab.activePaneID == paneID
                    && shell.tab.nativeActiveTabIsVisible
                    && shell.tab.nativeActivePaneIsVisible
                    && shell.tab.nativeActivePaneHasFocus
                    && visibleSidebarIsSettled(readback)
            }
        }

        private nonisolated static func projectionAdvanced(
            from baseline: RepoExplorerPerformanceProofReadback,
            to candidate: RepoExplorerPerformanceProofReadback
        ) -> Bool {
            candidate.semanticGeneration > baseline.semanticGeneration
                && candidate.acknowledgedRevision > baseline.acknowledgedRevision
                && candidate.visibleGeneration > baseline.visibleGeneration
        }

        private nonisolated static func nativeVisibleProjectionMatches(
            _ readback: SidebarPerformanceProofReadback
        ) -> Bool {
            readback.shell.nativeVisibleProjection?.matches(
                materializationGeneration: readback.repoExplorer.visibleGeneration,
                materializationFingerprint: readback.repoExplorer.materializationFingerprint
            ) == true
        }

        nonisolated static func visibleSidebarIsSettled(
            _ readback: SidebarPerformanceProofReadback
        ) -> Bool {
            let repoExplorer = readback.repoExplorer
            let shell = readback.shell
            return repoExplorer.presentationIsReady
                && repoExplorer.isDemanded
                && repoExplorer.accessibilityDisposition == .ready
                && !shell.semanticSidebarIsCollapsed
                && !shell.nativeSidebarIsCollapsed
                && shell.nativeSidebarGeometryIsVisible
                && shell.nativeSidebarAccessibilityIsReady
                && shell.nativePresentedRowCount == repoExplorer.representedRowCount
                && nativeVisibleProjectionMatches(readback)
                && readback.windowAttendance.isAttended
        }
    }

    enum SidebarPerformanceProofPopulation: String, Sendable {
        case zeroPTYIdle = "zero_pty_idle"
        case searchClear = "search_clear"
        case grouping
        case hideShow = "hide_show"
        case tabSwitch = "tab_switch"

        init?(kind: AgentStudioStartupDiagnosticAction.Kind) {
            switch kind {
            case .sidebarCPUZeroPTYIdle: self = .zeroPTYIdle
            case .sidebarCPUQuiescentPTYIdle: return nil
            case .sidebarCPUSearchClear: self = .searchClear
            case .sidebarCPUGrouping: self = .grouping
            case .sidebarCPUHideShow: self = .hideShow
            case .sidebarCPUTabSwitch: self = .tabSwitch
            default: return nil
            }
        }

        var isIdle: Bool { self == .zeroPTYIdle }
    }

    @MainActor
    final class SidebarPerformanceProofSession {
        private struct WindowAttendanceEdgeLatchState {
            var armedObservationGeneration: UInt64?
            var observedEdge = false

            mutating func arm(observationGeneration: UInt64) {
                armedObservationGeneration = observationGeneration
            }

            mutating func observeEdge(observationGeneration: UInt64) {
                guard armedObservationGeneration == observationGeneration else { return }
                observedEdge = true
            }

            mutating func disarm() {
                armedObservationGeneration = nil
            }
        }

        private let population: SidebarPerformanceProofPopulation
        private let window: NSWindow
        private let recorder: AgentStudioStartupTraceRecorder
        private let performanceRecorder: AgentStudioPerformanceTraceRecorder?
        private let delay: AsyncDelay
        private let settleRepositoryFactDemandAdmission: @MainActor @Sendable () async -> Void
        private let readAttendance: @MainActor () -> SidebarPerformanceProofWindowAttendance
        private let readShell: @MainActor () -> SidebarPerformanceProofShellReadback?
        private let readbackStream: AsyncStream<SidebarPerformanceProofReadback>
        private let readbackContinuation: AsyncStream<SidebarPerformanceProofReadback>.Continuation
        nonisolated private let windowAttendanceEdgeLatch = Mutex(
            WindowAttendanceEdgeLatchState())
        private var latestRepoExplorerReadback: RepoExplorerPerformanceProofReadback?
        private var latestReadback: SidebarPerformanceProofReadback?
        private var actionTracker = SidebarPerformanceProofActionTracker()
        private var observesShellState = false
        private var observesWindowAttendance = false
        private var windowAttendanceObservationGeneration: UInt64 = 0
        private var didEnterReadyPopulation = false
        private var firstUnattendedReadback: SidebarPerformanceProofWindowAttendance?
        private var didRecordWindowAttendanceFailure = false
        private var workloadBaseline: SidebarPerformanceTerminalWorkloadSnapshot?
        private var didCompleteWorkloadProof = false

        init(
            population: SidebarPerformanceProofPopulation,
            window: NSWindow,
            recorder: AgentStudioStartupTraceRecorder,
            performanceRecorder: AgentStudioPerformanceTraceRecorder?,
            delay: AsyncDelay = .taskSleep,
            settleRepositoryFactDemandAdmission: @escaping @MainActor @Sendable () async -> Void = {},
            readAttendance: (@MainActor () -> SidebarPerformanceProofWindowAttendance)? = nil,
            readShell: @escaping @MainActor () -> SidebarPerformanceProofShellReadback?
        ) {
            self.population = population
            self.window = window
            self.recorder = recorder
            self.performanceRecorder = performanceRecorder
            self.delay = delay
            self.settleRepositoryFactDemandAdmission = settleRepositoryFactDemandAdmission
            self.readAttendance =
                readAttendance ?? {
                    SidebarPerformanceProofWindowAttendance.capture(window: window)
                }
            self.readShell = readShell
            (readbackStream, readbackContinuation) = AsyncStream.makeStream(
                of: SidebarPerformanceProofReadback.self,
                bufferingPolicy: .bufferingNewest(1)
            )
        }

        func receive(_ readback: RepoExplorerPerformanceProofReadback) {
            latestRepoExplorerReadback = readback
            publishCurrentReadback()
        }

        func run() async -> Bool {
            observesShellState = true
            observesWindowAttendance = true
            observeShellState()
            observeWindowAttendance()
            var retainsObservationAfterRun = false
            defer {
                if !retainsObservationAfterRun {
                    stopObservingProofState()
                }
            }
            await Task.yield()
            await settleRepositoryFactDemandAdmission()
            guard await waitForInitialVisibleReadback() else {
                record(
                    "performance.sidebar.proof_action.failed",
                    sequence: 0,
                    outcome: "missing_visible_readback",
                    additionalAttributes: visibleReadbackFailureAttributes()
                )
                return false
            }
            guard let performanceRecorder else {
                record("performance.sidebar.proof_action.failed", sequence: 0, outcome: "missing_workload_recorder")
                return false
            }
            didEnterReadyPopulation = true
            guard let readinessAttendance = observeWindowAttendance(armingEdgeLatch: true) else {
                return false
            }
            recordWindowAttendanceEdgeFailureIfNeeded(currentAttendance: readinessAttendance)
            guard firstUnattendedReadback == nil,
                !windowAttendanceEdgeWasObserved(),
                readinessAttendance.isAttended
            else { return false }
            let workloadBaseline = performanceRecorder.beginSidebarPerformanceWorkloadProof()
            self.workloadBaseline = workloadBaseline
            record(
                "performance.sidebar.proof_population.ready",
                sequence: 0,
                outcome: "settled",
                additionalAttributes: workloadAttributes(
                    workloadBaseline,
                    terminalInputKey: "agentstudio.performance.sidebar.proof.terminal_input_baseline",
                    terminalOutputKey: "agentstudio.performance.sidebar.proof.terminal_output_baseline",
                    orderedCommandKey: "agentstudio.performance.sidebar.proof.ordered_command_baseline"
                )
            )
            if population.isIdle {
                retainsObservationAfterRun = true
                return true
            }
            do {
                try await delay.wait(AppPolicies.SidebarPerformanceProof.quiescenceInterval)
            } catch {
                return false
            }
            let actionCount = max(
                AppPolicies.SidebarPerformanceProof.requiredSuccessfulActionCount,
                AppPolicies.SidebarPerformanceProof.requiredActionBearingSampleCount
            )
            for sequence in 1...actionCount {
                guard await runAction(sequence: sequence) else { return false }
            }
            return completeWorkloadProof(sequence: actionCount)
        }

        @discardableResult
        func completeIdlePopulationForTermination() -> Bool {
            guard population.isIdle else { return false }
            let completed = completeWorkloadProof(sequence: 0)
            stopObservingProofState()
            return completed
        }

        private func runAction(sequence: Int) async -> Bool {
            guard let baseline = latestReadback,
                let expectedOutcome = expectedOutcome(sequence: sequence, baseline: baseline)
            else {
                record("performance.sidebar.proof_action.failed", sequence: sequence, outcome: "invalid_baseline")
                return false
            }
            await waitForSamplerBoundary()
            guard
                let outstandingAction = actionTracker.begin(
                    sequence: sequence,
                    baseline: baseline,
                    expectedOutcome: expectedOutcome
                )
            else {
                record("performance.sidebar.proof_action.failed", sequence: sequence, outcome: "overlap")
                return false
            }
            record(
                "performance.sidebar.proof_action.started",
                sequence: sequence,
                outcome: "started",
                additionalAttributes: proofReadbackAttributes(outstandingAction.baseline)
            )

            let settled: Bool
            if population == .searchClear {
                settled = await runSearchAndClear(sequence: sequence, filteredAction: outstandingAction)
            } else {
                guard dispatchAction(expectedOutcome: expectedOutcome) else {
                    _ = actionTracker.complete(sequence: sequence)
                    record("performance.sidebar.proof_action.failed", sequence: sequence, outcome: "dispatch_failed")
                    return false
                }
                settled = await waitForSettlement(of: outstandingAction)
            }

            guard actionTracker.complete(sequence: sequence) else {
                record("performance.sidebar.proof_action.failed", sequence: sequence, outcome: "token_mismatch")
                return false
            }
            record(
                settled ? "performance.sidebar.proof_action.settled" : "performance.sidebar.proof_action.failed",
                sequence: sequence,
                outcome: settled ? "settled" : "readback_timeout",
                additionalAttributes: latestReadback.map(proofReadbackAttributes) ?? [:]
            )
            return settled
        }

        private func runSearchAndClear(
            sequence: Int,
            filteredAction: SidebarPerformanceProofOutstandingAction
        ) async -> Bool {
            guard case .search(let fixtureQuery) = filteredAction.expectedOutcome else { return false }
            AppCommandDispatcher.shared.dispatch(.filterSidebar)
            await Task.yield()
            await Task.yield()
            let inputDriver = SidebarPerformanceProofNativeInputDriver(delay: delay)
            guard await inputDriver.typeFixtureQuery(in: window),
                await waitForSettlement(of: filteredAction),
                let filteredReadback = latestReadback,
                let clearAction = actionTracker.advance(
                    sequence: sequence,
                    baseline: filteredReadback,
                    expectedOutcome: .search(query: "")
                ),
                inputDriver.clearFixtureQuery(in: window)
            else { return false }
            _ = fixtureQuery
            return await waitForSettlement(of: clearAction)
        }

        private func expectedOutcome(
            sequence: Int,
            baseline: SidebarPerformanceProofReadback
        ) -> SidebarPerformanceProofExpectedOutcome? {
            switch population {
            case .searchClear:
                return .search(query: AppPolicies.SidebarPerformanceProof.fixtureQuery)
            case .grouping:
                return .grouping([.repo, .activity][sequence % 2])
            case .hideShow:
                return .sidebarCollapsed(!baseline.shell.nativeSidebarIsCollapsed)
            case .tabSwitch:
                let targetIndex = sequence.isMultiple(of: 2) ? 0 : 1
                guard baseline.shell.tab.orderedTabIDs.indices.contains(targetIndex) else { return nil }
                let tabID = baseline.shell.tab.orderedTabIDs[targetIndex]
                guard let paneID = baseline.shell.tab.activePaneIDByTabID[tabID] else { return nil }
                return .tabSelection(tabID: tabID, paneID: paneID)
            case .zeroPTYIdle:
                return nil
            }
        }

        private func dispatchAction(
            expectedOutcome: SidebarPerformanceProofExpectedOutcome
        ) -> Bool {
            switch expectedOutcome {
            case .search:
                return false
            case .grouping(let groupingMode):
                AppCommandDispatcher.shared.dispatch(.showReposSidebar)
                let command: AppCommand
                switch groupingMode {
                case .repo: command = .setReposGroupingRepo
                case .activity: command = .setReposGroupingActivity
                case .tab: return false
                }
                AppCommandDispatcher.shared.dispatch(command)
                return true
            case .sidebarCollapsed:
                AppCommandDispatcher.shared.dispatch(.toggleSidebar)
                return true
            case .tabSelection(let tabID, _):
                guard let tabIndex = latestReadback?.shell.tab.orderedTabIDs.firstIndex(of: tabID) else {
                    return false
                }
                let command: AppCommand = tabIndex == 0 ? .selectTab1 : .selectTab2
                AppCommandDispatcher.shared.dispatch(command)
                return true
            }
        }

        private func waitForSettlement(
            of outstandingAction: SidebarPerformanceProofOutstandingAction
        ) async -> Bool {
            let readbackSettled: Bool
            if let latestReadback,
                SidebarPerformanceProofActionTracker.matches(latestReadback, action: outstandingAction)
            {
                readbackSettled = true
            } else {
                readbackSettled = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { [readbackStream] in
                        for await readback in readbackStream {
                            if SidebarPerformanceProofActionTracker.matches(
                                readback,
                                action: outstandingAction
                            ) {
                                return true
                            }
                        }
                        return false
                    }
                    group.addTask { [delay] in
                        do {
                            try await delay.wait(AppPolicies.SidebarPerformanceProof.actionReadbackTimeout)
                        } catch {}
                        return false
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            }
            guard readbackSettled,
                readAttendance().isAttended
            else { return false }
            await settleRepositoryFactDemandAdmission()
            return true
        }

        private func waitForInitialVisibleReadback() async -> Bool {
            if let latestReadback,
                SidebarPerformanceProofActionTracker.visibleSidebarIsSettled(latestReadback)
            {
                return readAttendance().isAttended
            }
            let readbackSettled = await withTaskGroup(of: Bool.self) { group in
                group.addTask { [readbackStream] in
                    for await readback in readbackStream {
                        if SidebarPerformanceProofActionTracker.visibleSidebarIsSettled(readback) {
                            return true
                        }
                    }
                    return false
                }
                group.addTask { [delay] in
                    do {
                        try await delay.wait(AppPolicies.SidebarPerformanceProof.fixturePreparationTimeout)
                    } catch {}
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
            return readbackSettled
                && readAttendance().isAttended
        }

        @discardableResult
        private func observeWindowAttendance(
            afterChangeFrom previousGeneration: UInt64? = nil,
            armingEdgeLatch: Bool = false
        ) -> SidebarPerformanceProofWindowAttendance? {
            guard observesWindowAttendance else { return nil }
            if let previousGeneration,
                previousGeneration != windowAttendanceObservationGeneration
            {
                return nil
            }
            windowAttendanceObservationGeneration &+= 1
            let observationGeneration = windowAttendanceObservationGeneration
            if armingEdgeLatch {
                windowAttendanceEdgeLatch.withLock {
                    $0.arm(observationGeneration: observationGeneration)
                }
            }
            let attendance = withObservationTracking {
                readAttendance()
            } onChange: { [weak self] in
                self?.windowAttendanceDidChange(observationGeneration: observationGeneration)
            }
            acceptWindowAttendance(attendance)
            recordWindowAttendanceEdgeFailureIfNeeded(currentAttendance: attendance)
            return attendance
        }

        nonisolated private func windowAttendanceDidChange(observationGeneration: UInt64) {
            windowAttendanceEdgeLatch.withLock {
                $0.observeEdge(observationGeneration: observationGeneration)
            }
            Task { @MainActor [weak self] in
                self?.observeWindowAttendance(afterChangeFrom: observationGeneration)
            }
        }

        func acceptWindowAttendance(_ attendance: SidebarPerformanceProofWindowAttendance) {
            guard didEnterReadyPopulation,
                firstUnattendedReadback == nil,
                !attendance.isAttended
            else { return }
            firstUnattendedReadback = attendance
            recordWindowAttendanceFailure(attendance)
        }

        private func recordWindowAttendanceEdgeFailureIfNeeded(
            currentAttendance: SidebarPerformanceProofWindowAttendance
        ) {
            guard windowAttendanceEdgeWasObserved() else { return }
            recordWindowAttendanceFailure(currentAttendance)
        }

        private func recordWindowAttendanceFailure(
            _ attendance: SidebarPerformanceProofWindowAttendance
        ) {
            guard !didRecordWindowAttendanceFailure else { return }
            didRecordWindowAttendanceFailure = true
            record(
                "performance.sidebar.proof_action.failed",
                sequence: 0,
                outcome: "window_attendance_lost",
                additionalAttributes: attendanceAttributes(
                    attendance, prefix: "agentstudio.performance.sidebar.proof.attendance_lost.")
            )
        }

        private func windowAttendanceEdgeWasObserved() -> Bool {
            windowAttendanceEdgeLatch.withLock { $0.observedEdge }
        }

        private func stopObservingProofState() {
            observesShellState = false
            observesWindowAttendance = false
            windowAttendanceEdgeLatch.withLock { $0.disarm() }
            readbackContinuation.finish()
        }

        private func observeShellState() {
            guard observesShellState else { return }
            withObservationTracking {
                publishCurrentReadback()
            } onChange: { [weak self] in
                Task { @MainActor in
                    await Task.yield()
                    await Task.yield()
                    await Task.yield()
                    self?.observeShellState()
                }
            }
        }

        private func publishCurrentReadback() {
            guard let latestRepoExplorerReadback, let shell = readShell() else { return }
            let readback = SidebarPerformanceProofReadback(
                repoExplorer: latestRepoExplorerReadback,
                shell: shell,
                windowAttendance: readAttendance()
            )
            latestReadback = readback
            readbackContinuation.yield(readback)
        }

        private func visibleReadbackFailureAttributes() -> [String: AgentStudioTraceValue] {
            let prefix = "agentstudio.performance.sidebar.proof.initial_readback."
            var attributes = attendanceAttributes(readAttendance(), prefix: prefix)
            attributes[prefix + "present"] = .bool(latestReadback != nil)
            guard let latestReadback else { return attributes }
            let repoExplorer = latestReadback.repoExplorer
            let shell = latestReadback.shell
            attributes.merge([
                prefix + "repo_demanded": .bool(repoExplorer.isDemanded),
                prefix + "repo_presentation_ready": .bool(repoExplorer.presentationIsReady),
                prefix + "repo_accessibility": .string(
                    repoExplorer.accessibilityDisposition.rawValue),
                prefix + "semantic_collapsed": .bool(shell.semanticSidebarIsCollapsed),
                prefix + "native_collapsed": .bool(shell.nativeSidebarIsCollapsed),
                prefix + "native_geometry_visible": .bool(shell.nativeSidebarGeometryIsVisible),
                prefix + "native_accessibility_ready": .bool(
                    shell.nativeSidebarAccessibilityIsReady),
                prefix + "represented_row_count": .int(repoExplorer.representedRowCount),
                prefix + "native_row_count": .int(shell.nativePresentedRowCount ?? -1),
            ]) { _, newValue in newValue }
            return attributes
        }

        private func attendanceAttributes(
            _ attendance: SidebarPerformanceProofWindowAttendance,
            prefix: String
        ) -> [String: AgentStudioTraceValue] {
            [
                prefix + "app_hidden": .bool(attendance.applicationIsHidden),
                prefix + "app_active": .bool(attendance.applicationIsActive),
                prefix + "window_visible": .bool(attendance.windowIsVisible),
                prefix + "window_key": .bool(attendance.windowIsKey),
                prefix + "window_miniaturized": .bool(attendance.windowIsMiniaturized),
                prefix + "window_on_active_space": .bool(attendance.windowIsOnActiveSpace),
                prefix + "window_occlusion_visible": .bool(attendance.windowOcclusionIsVisible),
            ]
        }

        private func waitForSamplerBoundary() async {
            let interval = AppPolicies.SidebarPerformanceProof.sampleInterval.nanosecondsForTaskSleep
            let now = DispatchTime.now().uptimeNanoseconds
            let remainder = now % interval
            if remainder > 0 {
                try? await delay.wait(.nanoseconds(Int64(interval - remainder)))
            }
            try? await delay.wait(AppPolicies.SidebarPerformanceProof.actionSampleStartOffset)
        }

        private func record(
            _ message: String,
            sequence: Int,
            outcome: String,
            additionalAttributes: [String: AgentStudioTraceValue] = [:]
        ) {
            recorder.recordAppStartup(
                message,
                phase: "sidebar_performance_proof",
                outcome: outcome,
                attributes: [
                    "agentstudio.performance.sidebar.proof.population": .string(population.rawValue),
                    "agentstudio.performance.sidebar.proof.action.sequence": .int(sequence),
                    "agentstudio.performance.sidebar.proof.monotonic_ns": .int(
                        Int(DispatchTime.now().uptimeNanoseconds)
                    ),
                ].merging(additionalAttributes) { _, newValue in newValue }
            )
        }

        private func workloadAttributes(
            _ snapshot: SidebarPerformanceTerminalWorkloadSnapshot,
            terminalInputKey: String,
            terminalOutputKey: String,
            orderedCommandKey: String
        ) -> [String: AgentStudioTraceValue] {
            [
                terminalInputKey: .int(Int(snapshot.terminalInputCount)),
                terminalOutputKey: .int(Int(snapshot.terminalOutputAdvancementCount)),
                orderedCommandKey: .int(Int(snapshot.orderedCommandCount)),
            ]
        }

        private func proofReadbackAttributes(
            _ readback: SidebarPerformanceProofReadback
        ) -> [String: AgentStudioTraceValue] {
            let nativeProjection = readback.shell.nativeVisibleProjection
            let nativeProjectionRequired =
                readback.shell.nativeSidebarGeometryIsVisible
                && readback.repoExplorer.presentationIsReady
            let nativeProjectionMatches =
                nativeProjection?.matches(
                    materializationGeneration: readback.repoExplorer.visibleGeneration,
                    materializationFingerprint: readback.repoExplorer.materializationFingerprint
                ) == true
            return [
                "agentstudio.performance.sidebar.proof.readback.semantic_generation": .int(
                    readback.repoExplorer.semanticGeneration),
                "agentstudio.performance.sidebar.proof.readback.acknowledged_revision": .int(
                    Int(clamping: readback.repoExplorer.acknowledgedRevision)),
                "agentstudio.performance.sidebar.proof.readback.visible_generation": .int(
                    Int(clamping: readback.repoExplorer.visibleGeneration)),
                "agentstudio.performance.sidebar.proof.readback.materialization_fingerprint": .int(
                    Int(bitPattern: UInt(readback.repoExplorer.materializationFingerprint))),
                "agentstudio.performance.sidebar.proof.readback.native_materialization_generation": .int(
                    Int(clamping: nativeProjection?.materializationGeneration ?? 0)),
                "agentstudio.performance.sidebar.proof.readback.native_materialization_fingerprint": .int(
                    Int(bitPattern: UInt(nativeProjection?.materializationFingerprint ?? 0))),
                "agentstudio.performance.sidebar.proof.readback.native_projection_required": .bool(
                    nativeProjectionRequired),
                "agentstudio.performance.sidebar.proof.readback.native_projection_matches": .bool(
                    nativeProjectionMatches),
                "agentstudio.performance.sidebar.proof.readback.inactive_repository_header.count": .int(
                    readback.repoExplorer.inactiveRepositoryHeaderCount),
                "agentstudio.performance.sidebar.proof.readback.suppressed_repository_fact_row.count": .int(
                    readback.repoExplorer.suppressedRepositoryFactRowCount),
                "agentstudio.performance.sidebar.proof.readback.updating_repository_header.count": .int(
                    readback.repoExplorer.updatingRepositoryHeaderCount),
                "agentstudio.performance.sidebar.proof.readback.grouping_mode": .string(
                    readback.repoExplorer.groupingMode.rawValue),
            ]
        }

        private func completeWorkloadProof(sequence: Int) -> Bool {
            guard !didCompleteWorkloadProof,
                let performanceRecorder,
                let workloadBaseline
            else { return false }
            didCompleteWorkloadProof = true
            let completionAttendance = readAttendance()
            acceptWindowAttendance(completionAttendance)
            recordWindowAttendanceEdgeFailureIfNeeded(currentAttendance: completionAttendance)
            let workloadCompletion = performanceRecorder.completeSidebarPerformanceWorkloadProof()
            let completionAttributes = workloadAttributes(
                workloadCompletion,
                terminalInputKey: "agentstudio.performance.sidebar.proof.terminal_input_completion",
                terminalOutputKey: "agentstudio.performance.sidebar.proof.terminal_output_completion",
                orderedCommandKey: "agentstudio.performance.sidebar.proof.ordered_command_completion"
            )
            guard workloadCompletion == workloadBaseline else {
                record(
                    "performance.sidebar.proof_action.failed",
                    sequence: sequence,
                    outcome: "fixture_workload_changed",
                    additionalAttributes: completionAttributes
                )
                return false
            }
            guard firstUnattendedReadback == nil,
                !windowAttendanceEdgeWasObserved(),
                completionAttendance.isAttended
            else {
                stopObservingProofState()
                return false
            }
            record(
                "performance.sidebar.proof_population.completed",
                sequence: sequence,
                outcome: "settled",
                additionalAttributes: completionAttributes
            )
            return true
        }
    }
#endif
