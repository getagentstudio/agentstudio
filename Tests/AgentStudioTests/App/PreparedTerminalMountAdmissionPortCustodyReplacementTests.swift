import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

/// R1 remediation (PR #330): an issued claim, or retained retry tracking,
/// must not survive a newer generation's cohort replacing this pane's
/// custody in `ViewRegistry`. Split from `PreparedTerminalMountAdmissionPortTests`
/// to keep that suite under the file-length lint budget.
@MainActor
@Suite("Prepared terminal mount admission custody replacement")
struct AdmissionCustodyReplacementTests {
    @Test("activation is rejected when a newer generation's cohort replaces custody")
    func activationIsRejectedWhenANewerGenerationsCohortReplacesCustody() async throws {
        // Arrange: generation A claims pane P.
        let generationA = try makeCustodyReplacementTestGeneration()
        let descriptor = makeCustodyReplacementTestDescriptor(pane: makeCustodyReplacementTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generationA,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingCustodyReplacementMountHandler(results: [.ready(surfaceID: UUIDv7.generate())])
        let portA = PreparedTerminalMountAdmissionPort(
            generation: generationA,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let claimOutcome = portA.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generationA,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generationA, ordinal: 0)
            )
        )
        guard case .claimed(let claim) = claimOutcome else {
            Issue.record("expected attempt 1 to be granted a claim")
            return
        }

        // Act: a newer generation's cohort (still containing P) replaces custody
        // before A's claim is activated.
        let generationB = try makeCustodyReplacementTestGeneration()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generationB,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let activationOutcome = await portA.activateClaimedTerminal(claim)

        // Assert
        #expect(activationOutcome == .rejected(.custodyReplaced))
        #expect(handler.admissions.isEmpty)
    }

    @Test("a retry claim is rejected when a newer generation's cohort replaces custody")
    func aRetryClaimIsRejectedWhenANewerGenerationsCohortReplacesCustody() async throws {
        // Arrange: generation A claims pane P, attempt 1 fails retryably so the
        // port keeps `.awaitingRetryProposal` tracking for pane P.
        let generationA = try makeCustodyReplacementTestGeneration()
        let descriptor = makeCustodyReplacementTestDescriptor(pane: makeCustodyReplacementTestPane())
        let paneID = descriptor.paneID
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generationA,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let handler = RecordingCustodyReplacementMountHandler(
            results: [.failed(failure: .surfaceCreationFailed(code: "transient"), retry: .retry)]
        )
        let portA = PreparedTerminalMountAdmissionPort(
            generation: generationA,
            initialFramesByPaneID: [paneID: frame],
            viewRegistry: registry,
            mountHandler: handler,
            descriptorsByPaneID: [paneID: descriptor]
        )
        let revision = TerminalVisibilityRevision(generation: generationA, ordinal: 0)
        let firstClaimOutcome = portA.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generationA,
                paneID: paneID,
                attempt: 1,
                appliedVisibilityRevision: revision
            )
        )
        guard case .claimed(let firstClaim) = firstClaimOutcome else {
            Issue.record("expected attempt 1 to be granted a claim")
            return
        }
        _ = await portA.activateClaimedTerminal(firstClaim)

        // Act: a newer generation's cohort (still containing P) replaces custody
        // between A's retry attempts.
        let generationB = try makeCustodyReplacementTestGeneration()
        registry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generationB,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let retryOutcome = portA.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generationA,
                paneID: paneID,
                attempt: 2,
                appliedVisibilityRevision: revision
            )
        )

        // Assert: no second claim is minted.
        #expect(retryOutcome == .rejected(.custodyUnavailableForClaim))
        #expect(handler.admissions.count == 1)
    }
}

@MainActor
private final class RecordingCustodyReplacementMountHandler: PreparedTerminalMountHandling {
    private var results: [TerminalActivationAttemptResult]
    private(set) var admissions: [TerminalActivationAdmission] = []

    init(results: [TerminalActivationAttemptResult]) {
        self.results = results
    }

    func mountPreparedTerminalContent(
        admission: TerminalActivationAdmission,
        initialFrame: NSRect?,
        authority: TerminalSurfaceCreationAuthority
    ) async -> TerminalActivationAttemptResult {
        admissions.append(admission)
        return results.removeFirst()
    }
}

@MainActor
private func makeCustodyReplacementTestGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}

private func makeCustodyReplacementTestPane() -> Pane {
    Pane(
        id: UUIDv7.generate(),
        content: .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: .generateUUIDv7()
            )
        ),
        metadata: PaneMetadata(
            launchDirectory: URL(filePath: "/tmp/prepared-terminal-admission-custody-replacement"),
            title: "Prepared Terminal"
        )
    )
}

private func makeCustodyReplacementTestDescriptor(pane: Pane) -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal test requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: .activeVisible,
        hostPlacement: .tab(tabID: UUIDv7.generate())
    )
}
