import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Sidebar performance proof startup diagnostics", .serialized)
struct SidebarPerformanceProofStartupDiagnosticTests {
    @Test("performance readback consumes precomputed materialization summary in O(1)")
    func performanceReadbackDoesNotScanMaterializedRowsOnMainActor() throws {
        let adapterSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift",
            encoding: .utf8
        )
        let snapshotSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerMaterializationSnapshot.swift",
            encoding: .utf8
        )
        #expect(adapterSource.contains("performanceProofPresentationSummary"))
        #expect(!adapterSource.contains("visibleRows.count"))
        #expect(snapshotSource.contains("for (index, row) in rows.enumerated()"))
        #expect(snapshotSource.contains("inactiveRepositoryHeaderCount += 1"))
        #expect(snapshotSource.contains("suppressedRepositoryFactRowCount += 1"))
    }

    @Test("idle proof permanently latches a synchronous attendance lapse and recovery")
    func idleProofLatchesSynchronousAttendanceLapseBeforeObservationReregistration() async throws {
        let appLifecycleStore = AppLifecycleAtom()
        appLifecycleStore.setActive(true)
        let traceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-idle-attendance-edge-tests", isDirectory: true)
            .appendingPathComponent(UUIDv7.generate().uuidString, isDirectory: true)
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_TAGS": "app.startup",
            ]),
            processIdentifier: 921,
            timeUnixNano: { 909 }
        )
        let recorder = AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
        let performanceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: nil)
        let attendedReadback = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo
        )
        let session = SidebarPerformanceProofSession(
            population: .zeroPTYIdle,
            window: NSWindow(),
            recorder: recorder,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            performanceRecorder: performanceRecorder,
            readAttendance: {
                self.makeWindowAttendance(applicationIsActive: appLifecycleStore.isActive)
            },
            readShell: { attendedReadback.shell }
        )
        session.receive(attendedReadback.repoExplorer)

        #expect(await session.run())
        appLifecycleStore.setActive(false)
        appLifecycleStore.setActive(true)
        #expect(!session.completeIdlePopulationForTermination())

        try await recorder.drain()
        let outputFileURL = try #require(traceRuntime.outputFileURL)
        let traceContents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(traceContents.contains("performance.sidebar.proof_population.ready"))
        #expect(traceContents.contains("performance.sidebar.proof_action.failed"))
        #expect(
            traceContents.components(separatedBy: "window_attendance_lost").count - 1 == 1
        )
        #expect(traceContents.contains("attendance_lost.app_active"))
        #expect(!traceContents.contains("performance.sidebar.proof_population.completed"))
    }

    @Test("idle proof latches every attendance lapse after population readiness")
    func idleProofRejectsEveryPostReadyAttendanceLapse() async throws {
        let unattendedCases: [(String, SidebarPerformanceProofWindowAttendance)] = [
            ("inactive", makeWindowAttendance(applicationIsActive: false)),
            ("hidden", makeWindowAttendance(applicationIsHidden: true)),
            ("invisible", makeWindowAttendance(windowIsVisible: false)),
            ("non_key", makeWindowAttendance(windowIsKey: false)),
            ("miniaturized", makeWindowAttendance(windowIsMiniaturized: true)),
            ("off_active_space", makeWindowAttendance(windowIsOnActiveSpace: false)),
            ("occluded", makeWindowAttendance(windowOcclusionIsVisible: false)),
        ]

        for (caseName, unattended) in unattendedCases {
            let traceDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sidebar-idle-attendance-tests", isDirectory: true)
                .appendingPathComponent(UUIDv7.generate().uuidString, isDirectory: true)
            let traceRuntime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                    "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                    "AGENTSTUDIO_TRACE_TAGS": "app.startup",
                ]),
                processIdentifier: 921,
                timeUnixNano: { 909 }
            )
            let recorder = AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
            let performanceRecorder = AgentStudioPerformanceTraceRecorder(traceRuntime: nil)
            let attendedReadback = makeReadback(
                semanticGeneration: 7,
                acknowledgedRevision: 11,
                visibleGeneration: 13,
                groupingMode: .repo,
                nativeGroupingMode: .repo
            )
            let session = SidebarPerformanceProofSession(
                population: .zeroPTYIdle,
                window: NSWindow(),
                recorder: recorder,
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                performanceRecorder: performanceRecorder,
                readAttendance: { self.makeWindowAttendance() },
                readShell: { attendedReadback.shell }
            )
            session.receive(attendedReadback.repoExplorer)

            let becameReady = await session.run()
            #expect(becameReady, Comment(rawValue: caseName))
            session.acceptWindowAttendance(unattended)
            #expect(!session.completeIdlePopulationForTermination(), Comment(rawValue: caseName))

            try await recorder.drain()
            let outputFileURL = try #require(traceRuntime.outputFileURL)
            let traceContents = try String(contentsOf: outputFileURL, encoding: .utf8)
            #expect(
                traceContents.contains("performance.sidebar.proof_population.ready"),
                Comment(rawValue: caseName)
            )
            #expect(
                traceContents.contains("performance.sidebar.proof_action.failed"),
                Comment(rawValue: caseName)
            )
            #expect(
                traceContents.contains("window_attendance_lost"),
                Comment(rawValue: caseName)
            )
            #expect(
                !traceContents.contains("performance.sidebar.proof_population.completed"),
                Comment(rawValue: caseName)
            )
        }
    }

    @Test("strict window attendance distinguishes attended timeout and cancellation")
    func strictWindowAttendanceDispositionIsFailClosed() {
        let attended = makeWindowAttendance()
        #expect(attended.isAttended)
        #expect(
            AppDelegate.strictSidebarWindowAttendanceDisposition(
                for: attended,
                taskIsCancelled: false,
                deadlineReached: false
            ) == .attended
        )

        let partiallyAttended = makeWindowAttendance(windowIsKey: false)
        #expect(!partiallyAttended.isAttended)
        #expect(
            AppDelegate.strictSidebarWindowAttendanceDisposition(
                for: partiallyAttended,
                taskIsCancelled: false,
                deadlineReached: false
            ) == nil
        )
        #expect(
            AppDelegate.strictSidebarWindowAttendanceDisposition(
                for: partiallyAttended,
                taskIsCancelled: false,
                deadlineReached: true
            ) == .timedOut
        )
        #expect(
            AppDelegate.strictSidebarWindowAttendanceDisposition(
                for: attended,
                taskIsCancelled: true,
                deadlineReached: false
            ) == .cancelled
        )
    }

    @Test("cold mutation proof rejects nil or clean initial enrichment")
    func coldMutationProofRequiresChangedStatusContent() {
        #expect(!AppDelegate.strictColdLocalCompletionObserved(nil))
        let worktreeID = UUIDv7.generate()
        let repoID = UUIDv7.generate()
        let clean = WorktreeEnrichment(
            worktreeId: worktreeID,
            repoId: repoID,
            branch: "main",
            snapshot: GitWorkingTreeSnapshot(
                worktreeId: worktreeID,
                repoId: repoID,
                rootPath: URL(fileURLWithPath: "/tmp/strict-cold-proof"),
                summary: GitWorkingTreeSummary(
                    changed: 0, staged: 0, untracked: 0,
                    linesAdded: 0, linesDeleted: 0,
                    aheadCount: 0, behindCount: 0, hasUpstream: false
                ),
                branch: "main"
            )
        )
        #expect(!AppDelegate.strictColdLocalCompletionObserved(clean))
    }

    @Test("visible sidebar settlement requires complete proof window attendance")
    func visibleSidebarSettlementRequiresProofWindowAttendance() {
        let attendedReadback = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo
        )
        #expect(SidebarPerformanceProofActionTracker.visibleSidebarIsSettled(attendedReadback))

        let unattendedReadback = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            windowAttendance: makeWindowAttendance(applicationIsActive: false)
        )
        #expect(!SidebarPerformanceProofActionTracker.visibleSidebarIsSettled(unattendedReadback))
    }

    @Test("action tracker rejects overlap and mismatched or stale grouping readback")
    func actionTrackerRejectsOverlapAndMismatchedOrStaleReadback() throws {
        let baseline = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: baseline,
            expectedOutcome: .grouping(.activity)
        )
        let action = try #require(startedAction)

        let overlappingAction = tracker.begin(
            sequence: 2,
            baseline: baseline,
            expectedOutcome: .grouping(.tab)
        )
        #expect(overlappingAction == nil)
        #expect(
            !SidebarPerformanceProofActionTracker.matches(
                makeReadback(
                    semanticGeneration: 8,
                    acknowledgedRevision: 11,
                    visibleGeneration: 14,
                    groupingMode: .activity,
                    nativeGroupingMode: .activity
                ),
                action: action
            )
        )
        #expect(
            !SidebarPerformanceProofActionTracker.matches(
                makeReadback(
                    semanticGeneration: 8,
                    acknowledgedRevision: 12,
                    visibleGeneration: 14,
                    groupingMode: .tab,
                    nativeGroupingMode: .tab
                ),
                action: action
            )
        )
        #expect(
            !SidebarPerformanceProofActionTracker.matches(
                makeReadback(
                    semanticGeneration: 8,
                    acknowledgedRevision: 12,
                    visibleGeneration: 14,
                    groupingMode: .activity,
                    nativeGroupingMode: .repo
                ),
                action: action
            )
        )
        #expect(
            SidebarPerformanceProofActionTracker.matches(
                makeReadback(
                    semanticGeneration: 8,
                    acknowledgedRevision: 12,
                    visibleGeneration: 14,
                    groupingMode: .activity,
                    nativeGroupingMode: .activity
                ),
                action: action
            )
        )
        let mismatchedCompletion = tracker.complete(sequence: 2)
        #expect(!mismatchedCompletion)
        #expect(tracker.outstandingAction?.sequence == 1)
        let matchingCompletion = tracker.complete(sequence: 1)
        #expect(matchingCompletion)
        #expect(tracker.outstandingAction == nil)
    }

    @Test("action settlement rejects same-count native rows with stale generation, order, or membership")
    func actionSettlementRequiresGenerationMatchedNativeVisibleProjection() throws {
        let baseline = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            materializationFingerprint: 101,
            nativeVisibleProjection: .matching(
                materializationGeneration: 13,
                materializationFingerprint: 101,
                visibleFingerprint: 201,
                visibleRowCount: 24
            )
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: baseline,
            expectedOutcome: .grouping(.activity)
        )
        let action = try #require(startedAction)

        for mismatchedNativeProjection in [
            RepoExplorerNativeVisibleProjectionReadback.matching(
                materializationGeneration: 12,
                materializationFingerprint: 101,
                visibleFingerprint: 201,
                visibleRowCount: 24
            ),
            RepoExplorerNativeVisibleProjectionReadback(
                materializationGeneration: 14,
                materializationFingerprint: 102,
                expectedVisibleFingerprint: 201,
                actualVisibleFingerprint: 201,
                visibleRowCount: 24,
                actualBoundRowCount: 24
            ),
            RepoExplorerNativeVisibleProjectionReadback(
                materializationGeneration: 14,
                materializationFingerprint: 101,
                expectedVisibleFingerprint: 201,
                actualVisibleFingerprint: 202,
                visibleRowCount: 24,
                actualBoundRowCount: 24
            ),
            RepoExplorerNativeVisibleProjectionReadback(
                materializationGeneration: 14,
                materializationFingerprint: UInt64.max,
                expectedVisibleFingerprint: 201,
                actualVisibleFingerprint: 201,
                visibleRowCount: 24,
                actualBoundRowCount: 24
            ),
        ] {
            let candidate = makeReadback(
                semanticGeneration: 8,
                acknowledgedRevision: 12,
                visibleGeneration: 14,
                groupingMode: .activity,
                nativeGroupingMode: .activity,
                materializationFingerprint: 101,
                nativeVisibleProjection: mismatchedNativeProjection
            )
            #expect(!SidebarPerformanceProofActionTracker.matches(candidate, action: action))
        }

        let settled = makeReadback(
            semanticGeneration: 8,
            acknowledgedRevision: 12,
            visibleGeneration: 14,
            groupingMode: .activity,
            nativeGroupingMode: .activity,
            materializationFingerprint: 101,
            nativeVisibleProjection: .matching(
                materializationGeneration: 14,
                materializationFingerprint: 101,
                visibleFingerprint: 201,
                visibleRowCount: 24
            )
        )
        #expect(SidebarPerformanceProofActionTracker.matches(settled, action: action))
    }

    @Test("visibility settlement does not require an unrelated Repo Explorer revision")
    func visibilitySettlementAllowsAnEqualProjectionBaseline() throws {
        let baseline = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: baseline,
            expectedOutcome: .sidebarCollapsed(true)
        )
        let action = try #require(startedAction)
        let hidden = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: nil,
            isDemanded: false,
            presentationIsReady: false,
            accessibilityDisposition: .unavailable,
            sidebarIsCollapsed: true,
            nativeSidebarGeometryIsVisible: false,
            nativeSidebarAccessibilityIsReady: false,
            nativePresentedRowCount: nil
        )

        #expect(SidebarPerformanceProofActionTracker.matches(hidden, action: action))
    }

    @Test("expanded visibility settlement rejects a same-count stale native fingerprint")
    func visibilityExpansionRequiresCurrentNativeVisibleProjection() throws {
        let collapsed = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: nil,
            isDemanded: false,
            presentationIsReady: false,
            accessibilityDisposition: .unavailable,
            sidebarIsCollapsed: true,
            nativeSidebarGeometryIsVisible: false,
            nativeSidebarAccessibilityIsReady: false,
            nativePresentedRowCount: nil
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: collapsed,
            expectedOutcome: .sidebarCollapsed(false)
        )
        let action = try #require(startedAction)
        let stale = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            nativeVisibleProjection: .matching(
                materializationGeneration: 12,
                materializationFingerprint: 101,
                visibleFingerprint: 201,
                visibleRowCount: 24
            )
        )
        #expect(!SidebarPerformanceProofActionTracker.matches(stale, action: action))
    }

    @Test("search must settle filtered presentation before clearing")
    func searchRequiresFilteredSettlementBeforeClear() throws {
        let fixtureQuery = "worktree"
        let baseline = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            focusDisposition: .filterFocused,
            nativeFilterValue: ""
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: baseline,
            expectedOutcome: .search(query: fixtureQuery)
        )
        let filteredAction = try #require(startedAction)
        let prematurelyCleared = makeReadback(
            semanticGeneration: 8,
            acknowledgedRevision: 12,
            visibleGeneration: 14,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            focusDisposition: .filterFocused,
            nativeFilterValue: ""
        )
        #expect(!SidebarPerformanceProofActionTracker.matches(prematurelyCleared, action: filteredAction))

        let filtered = makeReadback(
            semanticGeneration: 8,
            acknowledgedRevision: 12,
            visibleGeneration: 14,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            query: fixtureQuery,
            focusDisposition: .filterFocused,
            nativeFilterValue: fixtureQuery
        )
        #expect(SidebarPerformanceProofActionTracker.matches(filtered, action: filteredAction))
        let advancedAction = tracker.advance(
            sequence: 1,
            baseline: filtered,
            expectedOutcome: .search(query: "")
        )
        let clearAction = try #require(advancedAction)
        let cleared = makeReadback(
            semanticGeneration: 9,
            acknowledgedRevision: 13,
            visibleGeneration: 15,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            focusDisposition: .filterFocused,
            nativeFilterValue: ""
        )
        #expect(SidebarPerformanceProofActionTracker.matches(cleared, action: clearAction))
    }

    @Test("tab settlement requires semantic identity native content and focus")
    func tabSettlementRequiresTheOwningNativeState() throws {
        let firstTabID = UUIDv7.generate()
        let secondTabID = UUIDv7.generate()
        let firstPaneID = UUIDv7.generate()
        let secondPaneID = UUIDv7.generate()
        let baseline = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            orderedTabIDs: [firstTabID, secondTabID],
            activeTabID: firstTabID,
            activePaneID: firstPaneID,
            activePaneIDByTabID: [firstTabID: firstPaneID, secondTabID: secondPaneID]
        )
        var tracker = SidebarPerformanceProofActionTracker()
        let startedAction = tracker.begin(
            sequence: 1,
            baseline: baseline,
            expectedOutcome: .tabSelection(tabID: secondTabID, paneID: secondPaneID)
        )
        let action = try #require(startedAction)
        let switchedWithoutFocus = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            orderedTabIDs: [firstTabID, secondTabID],
            activeTabID: secondTabID,
            activePaneID: secondPaneID,
            activePaneIDByTabID: [firstTabID: firstPaneID, secondTabID: secondPaneID],
            nativeActivePaneHasFocus: false
        )
        #expect(!SidebarPerformanceProofActionTracker.matches(switchedWithoutFocus, action: action))

        let settled = makeReadback(
            semanticGeneration: 7,
            acknowledgedRevision: 11,
            visibleGeneration: 13,
            groupingMode: .repo,
            nativeGroupingMode: .repo,
            orderedTabIDs: [firstTabID, secondTabID],
            activeTabID: secondTabID,
            activePaneID: secondPaneID,
            activePaneIDByTabID: [firstTabID: firstPaneID, secondTabID: secondPaneID]
        )
        #expect(SidebarPerformanceProofActionTracker.matches(settled, action: action))
    }

    @Test("shell accessibility readback resolves the selected grouping segment")
    func shellAccessibilityReadbackResolvesSelectedGroupingSegment() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        for groupingMode in RepoExplorerGroupingMode.allCases {
            let segment = SelectedSidebarGroupingAccessibilityButton(
                identifier: "repoSidebarGroupingSegment.\(groupingMode.rawValue)",
                label: groupingMode.title,
                isSelected: groupingMode == .activity
            )
            rootView.addSubview(segment)
        }
        let tableView = NSTableView(frame: NSRect(x: 0, y: 30, width: 300, height: 270))
        rootView.addSubview(tableView)

        #expect(
            SidebarPerformanceProofAccessibility.selectedRepoGroupingMode(in: rootView) == .activity
        )
        #expect(
            SidebarPerformanceProofAccessibility.firstDescendant(
                of: NSTableView.self,
                in: rootView
            ) === tableView
        )
    }
}

extension SidebarPerformanceProofStartupDiagnosticTests {
    @Test("strict CPU populations use fixed debug selectors and population-specific readback")
    func strictCPUPopulationsUseFixedDebugSelectorsAndOneCorrelatedAction() throws {
        let actionSource = try String(
            contentsOfFile: "Sources/AgentStudio/App/Boot/AgentStudioStartupDiagnosticAction.swift",
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOfFile: "Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift",
            encoding: .utf8
        )
        for selector in [
            "sidebar-cpu-zero-pty-idle", "sidebar-cpu-quiescent-pty-idle",
            "sidebar-cpu-search-clear", "sidebar-cpu-grouping", "sidebar-cpu-hide-show",
            "sidebar-cpu-tab-switch",
        ] {
            #expect(actionSource.contains(selector))
        }
        #expect(sessionSource.contains("private var actionTracker"))
        #expect(sessionSource.contains("guard outstandingAction == nil"))
        #expect(sessionSource.contains("SidebarPerformanceProofExpectedOutcome"))
        #expect(sessionSource.contains("nativeSelectedGroupingMode"))
        #expect(sessionSource.contains("nativeSidebarGeometryIsVisible"))
        #expect(sessionSource.contains("nativeActivePaneHasFocus"))
        #expect(sessionSource.contains("actionTracker.advance("))
        #expect(sessionSource.contains("commandDispatcher.dispatch"))
        #expect(sessionSource.contains("commandDispatcher.dispatch(.showReposSidebar)"))
        #expect(sessionSource.contains("case .repo: command = .setReposGroupingRepo"))
        #expect(sessionSource.contains("case .activity: command = .setReposGroupingActivity"))
        #expect(!sessionSource.contains("commandDispatcher.dispatch(.showPanesSidebar)"))
        #expect(!sessionSource.contains(".setPanesGroupingRepo"))
        #expect(!sessionSource.contains(".setPanesGroupingActivity"))
        #expect(!sessionSource.contains(".setPanesGroupingTab"))
        #expect(sessionSource.contains("SidebarPerformanceProofNativeInputDriver"))
        #expect(sessionSource.contains("performance.sidebar.proof_action.started"))
        #expect(sessionSource.contains("performance.sidebar.proof_action.settled"))
        #expect(sessionSource.contains("performance.sidebar.proof_action.failed"))
        let visibleReadback = try #require(
            sessionSource.range(of: "guard await waitForInitialVisibleReadback()")
        )
        let initialDemandSettlement = try #require(
            sessionSource.range(of: "await settleRepositoryFactDemandAdmission()")
        )
        let populationReady = try #require(
            sessionSource.range(of: "performance.sidebar.proof_population.ready")
        )
        let attendanceLatchAuthority = try #require(
            sessionSource.range(of: "didEnterReadyPopulation = true")
        )
        let armedAttendanceObservation = try #require(
            sessionSource.range(of: "observeWindowAttendance(armingEdgeLatch: true)")
        )
        let currentAttendanceBarrier = try #require(
            sessionSource.range(of: "readinessAttendance.isAttended")
        )
        #expect(initialDemandSettlement.lowerBound < visibleReadback.lowerBound)
        #expect(visibleReadback.lowerBound < populationReady.lowerBound)
        #expect(visibleReadback.lowerBound < attendanceLatchAuthority.lowerBound)
        #expect(attendanceLatchAuthority.lowerBound < armedAttendanceObservation.lowerBound)
        #expect(armedAttendanceObservation.lowerBound < currentAttendanceBarrier.lowerBound)
        #expect(currentAttendanceBarrier.lowerBound < populationReady.lowerBound)
        #expect(sessionSource.contains("windowAttendanceDidChange"))
        #expect(sessionSource.contains("windowAttendanceEdgeWasObserved"))
        #expect(
            sessionSource.contains(
                "SidebarPerformanceProofActionTracker.visibleSidebarIsSettled"
            )
        )
        let initialVisibleWaitStart = try #require(
            sessionSource.range(of: "private func waitForInitialVisibleReadback()")
        )
        let initialVisibleWaitEnd = try #require(
            sessionSource.range(
                of: "private func observeShellState()",
                range: initialVisibleWaitStart.upperBound..<sessionSource.endIndex
            )
        )
        let initialVisibleWait = sessionSource[
            initialVisibleWaitStart.lowerBound..<initialVisibleWaitEnd.lowerBound
        ]
        #expect(initialVisibleWait.contains("fixturePreparationTimeout"))
        #expect(!initialVisibleWait.contains("actionReadbackTimeout"))
        #expect(
            sessionSource.contains(
                "agentstudio.performance.sidebar.proof.initial_readback."
            )
        )
        #expect(sessionSource.contains("repo_demanded"))
        #expect(sessionSource.contains("native_accessibility_ready"))
        #expect(sessionSource.contains("app_hidden"))
        #expect(sessionSource.contains("app_active"))
        #expect(sessionSource.contains("window_miniaturized"))
        #expect(sessionSource.contains("window_on_active_space"))
        #expect(sessionSource.contains("window_occlusion_visible"))
        #expect(sessionSource.contains("native_row_count"))
        #expect(sessionSource.contains("retainsObservationAfterRun = true"))
        #expect(sessionSource.contains("firstUnattendedReadback == nil"))
        #expect(sessionSource.contains("await settleRepositoryFactDemandAdmission()"))
        #expect(!sessionSource.contains("socket"))
        #expect(!sessionSource.contains("FIFO"))
        #expect(!sessionSource.contains("NotificationCenter"))
        #expect(!sessionSource.contains("AppEventBus"))
        #expect(!sessionSource.contains("AppCommandIPC"))
    }

    @Test("sidebar performance search driver separates native typing from native clear")
    func sidebarPerformanceSearchDriverUsesNativeKeyEventsAndPolicyCadence() throws {
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+SidebarPerformanceProofStartupDiagnostics.swift",
            encoding: .utf8
        )
        #expect(source.contains("func typeFixtureQuery(in window: NSWindow) async -> Bool"))
        #expect(source.contains("func clearFixtureQuery(in window: NSWindow) -> Bool"))
        #expect(source.contains("NSEvent.keyEvent("))
        #expect(source.contains("window.sendEvent(event)"))
        #expect(source.contains("searchCharacterInterval"))
        #expect(source.contains("modifiers: [.command]"))
        #expect(source.contains("keyCode: 51"))
        #expect(!source.contains("setFilterText"))
        #expect(!source.contains("filterText ="))
        #expect(!source.contains("uiState."))
        #expect(!source.contains("AppCommandIPC"))
    }

    @Test("strict pane fixture registers native view slots before layout publication")
    func strictPaneFixtureRegistersNativeViewSlots() throws {
        let fixtureSource = try String(
            contentsOfFile: "Sources/AgentStudio/App/Boot/SidebarPerformanceProofFixture+RealSize.swift",
            encoding: .utf8
        )
        let diagnosticSource = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+SidebarPerformanceProofStartupDiagnostics.swift",
            encoding: .utf8
        )

        #expect(fixtureSource.contains("static func populateStrictPaneFleet("))
        #expect(fixtureSource.contains("viewRegistry: ViewRegistry"))
        #expect(fixtureSource.contains("viewRegistry.ensureSlot(for: pane.id)"))
        #expect(diagnosticSource.contains("SidebarPerformanceProofFixture.populateStrictPaneFleet("))
        #expect(diagnosticSource.contains("viewRegistry: viewRegistry"))
    }

    @Test("strict policy is projected before scan and fixture readiness is separate")
    func strictPolicyPrecedesScanAndFixtureReadinessIsSeparate() throws {
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+SidebarPerformanceProofStartupDiagnostics.swift",
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOfFile: "Sources/AgentStudio/App/Boot/SidebarPerformanceProofSession.swift",
            encoding: .utf8
        )

        let policyProjection = try #require(
            source.range(of: "app.startup_diagnostic.sidebar_proof.policy_projected")
        )
        let fixturePreparation = try #require(
            source.range(of: "await prepareStrictSidebarPerformanceProofFixture")
        )
        let fixtureReady = try #require(
            source.range(of: "app.startup_diagnostic.sidebar_proof.fixture_ready")
        )
        let foregroundActivation = try #require(
            source.range(of: "NSApp.activate(ignoringOtherApps: true)")
        )
        let unconditionalWindowOrdering = try #require(
            source.range(of: "window.orderFrontRegardless()")
        )
        let attendedWindowBarrier = try #require(
            source.range(of: "await waitForStrictSidebarWindowAttendance(window)")
        )
        let idempotentSidebarExpansion = try #require(
            source.range(
                of: "mainWindowController.expandSidebar()",
                range: foregroundActivation.upperBound..<source.endIndex
            )
        )
        let sessionRun = try #require(source.range(of: "let succeeded = await session.run()"))

        #expect(policyProjection.lowerBound < fixturePreparation.lowerBound)
        #expect(fixturePreparation.lowerBound < fixtureReady.lowerBound)
        #expect(fixtureReady.lowerBound < foregroundActivation.lowerBound)
        #expect(foregroundActivation.lowerBound < unconditionalWindowOrdering.lowerBound)
        #expect(unconditionalWindowOrdering.lowerBound < attendedWindowBarrier.lowerBound)
        #expect(attendedWindowBarrier.lowerBound < idempotentSidebarExpansion.lowerBound)
        #expect(foregroundActivation.lowerBound < idempotentSidebarExpansion.lowerBound)
        #expect(idempotentSidebarExpansion.lowerBound < sessionRun.lowerBound)
        #expect(foregroundActivation.lowerBound < sessionRun.lowerBound)
        #expect(source.contains("window.makeKeyAndOrderFront(nil)"))
        #expect(source.contains("_ = appLifecycleStore.isActive"))
        #expect(source.contains("windowLifecycleStore.preferredWorkspaceWindowId"))
        #expect(source.contains("windowLifecycleStore.presentationFacts(for: preferredWindowID)"))
        #expect(!source.contains("AppCommandDispatcher.shared.dispatch(.showWorktreeSidebar)"))
        #expect(source.contains("await commands.refreshWatchedFolders"))
        for attribute in [
            "open_source_root_present", "project_dev_root_present", "control_root_present",
            "discovered_repository_count", "discovered_worktree_count",
            "topology_fingerprint", "tab_count", "pane_model_count",
            "expected_session_variant",
        ] {
            #expect(source.contains("agentstudio.startup_diagnostic.sidebar_proof.\(attribute)"))
        }
        for policyAttribute in [
            "metrics_export_interval_ms",
            "git_status_physical_limit", "remote_reference_physical_limit",
            "forge_physical_limit", "git_maximum_settlement_ms",
        ] {
            #expect(source.contains("agentstudio.startup_diagnostic.sidebar_proof.\(policyAttribute)"))
        }
        for attribute in [
            "terminal_input_baseline", "terminal_output_baseline",
            "ordered_command_baseline",
        ] {
            #expect(sessionSource.contains("agentstudio.performance.sidebar.proof.\(attribute)"))
        }
    }

    private func makeReadback(
        semanticGeneration: Int,
        acknowledgedRevision: UInt64,
        visibleGeneration: UInt64,
        groupingMode: RepoExplorerGroupingMode,
        nativeGroupingMode: RepoExplorerGroupingMode?,
        query: String = "",
        isDemanded: Bool = true,
        presentationIsReady: Bool = true,
        accessibilityDisposition: RepoExplorerPerformanceProofReadback.AccessibilityDisposition = .ready,
        focusDisposition: RepoExplorerPerformanceProofReadback.FocusDisposition = .notFocused,
        sidebarIsCollapsed: Bool = false,
        nativeSidebarGeometryIsVisible: Bool = true,
        nativeFilterValue: String? = nil,
        nativeSidebarAccessibilityIsReady: Bool = true,
        nativePresentedRowCount: Int? = 24,
        materializationFingerprint: UInt64 = 101,
        nativeVisibleProjection: RepoExplorerNativeVisibleProjectionReadback? = nil,
        orderedTabIDs: [UUID] = [],
        activeTabID: UUID? = nil,
        activePaneID: UUID? = nil,
        activePaneIDByTabID: [UUID: UUID] = [:],
        nativeActivePaneHasFocus: Bool = true,
        windowAttendance: SidebarPerformanceProofWindowAttendance? = nil
    ) -> SidebarPerformanceProofReadback {
        SidebarPerformanceProofReadback(
            repoExplorer: RepoExplorerPerformanceProofReadback(
                semanticGeneration: semanticGeneration,
                acknowledgedRevision: acknowledgedRevision,
                visibleGeneration: visibleGeneration,
                representedRowCount: 24,
                materializationFingerprint: materializationFingerprint,
                groupingMode: groupingMode,
                query: query,
                isDemanded: isDemanded,
                presentationIsReady: presentationIsReady,
                focusDisposition: focusDisposition,
                accessibilityDisposition: accessibilityDisposition
            ),
            shell: SidebarPerformanceProofShellReadback(
                semanticSidebarIsCollapsed: sidebarIsCollapsed,
                nativeSidebarIsCollapsed: sidebarIsCollapsed,
                nativeSidebarGeometryIsVisible: nativeSidebarGeometryIsVisible,
                nativeFilterValue: nativeFilterValue,
                nativeSelectedGroupingMode: nativeGroupingMode,
                nativeSidebarAccessibilityIsReady: nativeSidebarAccessibilityIsReady,
                nativePresentedRowCount: nativePresentedRowCount,
                nativeVisibleProjection: nativeVisibleProjection
                    ?? .matching(
                        materializationGeneration: visibleGeneration,
                        materializationFingerprint: materializationFingerprint,
                        visibleFingerprint: 201,
                        visibleRowCount: nativePresentedRowCount ?? 0
                    ),
                tab: SidebarPerformanceProofTabReadback(
                    orderedTabIDs: orderedTabIDs,
                    activeTabID: activeTabID,
                    activePaneID: activePaneID,
                    activePaneIDByTabID: activePaneIDByTabID,
                    nativeActiveTabIsVisible: true,
                    nativeActivePaneIsVisible: true,
                    nativeActivePaneHasFocus: nativeActivePaneHasFocus
                )
            ),
            windowAttendance: windowAttendance ?? makeWindowAttendance()
        )
    }

    private func makeWindowAttendance(
        applicationIsActive: Bool = true,
        applicationIsHidden: Bool = false,
        windowIsVisible: Bool = true,
        windowIsKey: Bool = true,
        windowIsMiniaturized: Bool = false,
        windowIsOnActiveSpace: Bool = true,
        windowOcclusionIsVisible: Bool = true
    ) -> SidebarPerformanceProofWindowAttendance {
        SidebarPerformanceProofWindowAttendance(
            applicationIsActive: applicationIsActive,
            applicationIsHidden: applicationIsHidden,
            windowIsVisible: windowIsVisible,
            windowIsKey: windowIsKey,
            windowIsMiniaturized: windowIsMiniaturized,
            windowIsOnActiveSpace: windowIsOnActiveSpace,
            windowOcclusionIsVisible: windowOcclusionIsVisible
        )
    }
}

@MainActor
private final class SelectedSidebarGroupingAccessibilityButton: NSButton {
    private let fixedAccessibilityIdentifier: String
    private let fixedAccessibilityLabel: String
    private let fixedIsSelected: Bool

    init(identifier: String, label: String, isSelected: Bool) {
        fixedAccessibilityIdentifier = identifier
        fixedAccessibilityLabel = label
        fixedIsSelected = isSelected
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityIdentifier() -> String {
        fixedAccessibilityIdentifier
    }

    override func accessibilityLabel() -> String? {
        fixedAccessibilityLabel
    }

    override func isAccessibilitySelected() -> Bool {
        fixedIsSelected
    }
}
