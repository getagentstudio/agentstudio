import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

/// Program Design item 4 ("Staggered starts"): `TerminalActivationSchedulerTests.swift`
/// and `TerminalActivationSchedulerTestFakes.swift` are both already large,
/// so this narrowly-scoped, larger-scale case lives in its own suite file
/// (matching `TerminalActivationSchedulerSettlementRaceTests`'s own reason
/// for splitting out).
///
/// A dedicated cold-start slot gate was removed 2026-09-30: gating a cold
/// pane's surface creation behind a second semaphore would stall this
/// scheduler's single restore-drain worker behind a blocked candidate,
/// since that worker cannot skip a candidate and come back to it (see
/// `WorkspaceSurfaceCoordinator+TerminalContentMounting.swift`'s
/// `beginObservingColdStart` doc comment). Staggered starts now rely solely
/// on the scheduler's existing single-worker drain --
/// `restoreMaximumConcurrentAdmissions == 1`. The scheduler itself never
/// sees restore kind -- cold, warm and unverified panes are all plain
/// candidates to it -- so this proves the invariant that design actually
/// depends on, at a realistic scale: strict one-at-a-time admission across a
/// 20-member backlog, and a visible candidate mixed into that backlog
/// starting on its own turn rather than waiting behind the backlog ahead of
/// it.
@MainActor
@Suite("Terminal activation scheduler staggered starts", .serialized)
struct TerminalActivationSchedulerStaggeredStartsTests {
    @Test("a large hidden backlog starts one at a time, and a visible candidate mixed into it is never delayed")
    func aLargeHiddenBacklogStartsOneAtATimeAndAVisibleCandidateIsNeverDelayed() async throws {
        // Arrange
        let backlog = makeDescriptors(count: 20, priority: .hidden)
        let visibleCandidate = makeDescriptor(priority: .activeVisible)
        let port = ControlledTerminalActivationAdmissionPort()
        let scheduler = try await makeScheduler(entries: backlog + [visibleCandidate], port: port)
        let activation = Task { await scheduler.activate() }

        // Act / Assert: visible-first ranking admits the visible candidate
        // first, ahead of all 20 backlogged members -- it is never delayed
        // behind them.
        await port.waitUntilStartedCount(1)
        #expect(port.admissions.first?.descriptor.paneID == visibleCandidate.paneID)
        #expect(await scheduler.diagnostics().currentSimultaneousAdmissions == 1)
        port.releaseFirstPendingAsReady()

        // The remaining 20 backlogged members each start only after the
        // previous one was released -- never more than one admission in
        // flight at once, across the whole backlog.
        for expectedStartedCount in 2...21 {
            await port.waitUntilStartedCount(expectedStartedCount)
            #expect(await scheduler.diagnostics().currentSimultaneousAdmissions == 1)
            port.releaseFirstPendingAsReady()
        }
        _ = await activation.value

        #expect(port.admissions.count == 21)
        #expect(await scheduler.diagnostics().maximumSimultaneousAdmissions == 1)
    }

    private func makeScheduler(
        entries: [TerminalActivationDescriptor],
        port: some FakeTerminalActivationAdmissionPort
    ) async throws -> TerminalActivationScheduler {
        port.descriptorsByPaneID = Dictionary(uniqueKeysWithValues: entries.map { ($0.paneID, $0) })
        let scheduler = TerminalActivationScheduler(
            cohort: TerminalActivationCohort(
                generation: WorkspaceContentMountGeneration(),
                input: TerminalActivationInput(entries: entries)
            ),
            admissionPort: port
        )
        _ = await scheduler.installGeometryEligibility(Set(entries.map(\.paneID)))
        return scheduler
    }

    private func makeDescriptors(
        count: Int,
        priority: TerminalActivationVisibilityPriority
    ) -> [TerminalActivationDescriptor] {
        (0..<count).map { _ in makeDescriptor(priority: priority) }
    }

    private func makeDescriptor(
        priority: TerminalActivationVisibilityPriority
    ) -> TerminalActivationDescriptor {
        let pane = Pane(
            id: UUIDv7.generate(),
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: .generateUUIDv7()
                )
            ),
            metadata: PaneMetadata(
                launchDirectory: URL(filePath: "/tmp/terminal-activation-staggered-starts"),
                title: "Staggered starts test"
            )
        )
        return TerminalActivationDescriptor(
            pane: pane,
            visibilityPriority: priority,
            hostPlacement: .tab(tabID: UUIDv7.generate())
        )
    }
}
