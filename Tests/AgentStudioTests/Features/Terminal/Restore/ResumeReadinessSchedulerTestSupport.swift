import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

enum ResumeAdmissionFact: Equatable, Sendable { case claimed, started, finished }

@MainActor
final class ResumeReadinessAdmissionPort: TerminalActivationAdmissionPort {
    let descriptors: [PaneId: TerminalActivationDescriptor]
    private(set) var admissions: [TerminalActivationAdmission] = []
    private(set) var claims: [PaneId] = []
    private(set) var installedKinds: [PaneId: TerminalRestoreKind] = [:]
    private(set) var installations: [[PaneId: TerminalRestoreKind]] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var holds: [PaneId: HeldStep<TerminalActivationAdmission>] = [:]
    let facts: FactRecorder<UUID, ResumeAdmissionFact>
    private let source: LocalFactSource<UUID, ResumeAdmissionFact>

    init(entries: [TerminalActivationDescriptor]) throws {
        descriptors = Dictionary(uniqueKeysWithValues: entries.map { ($0.paneID, $0) })
        source = LocalFactSource(
            vocabulary: .init(
                describeScope: { $0.uuidString },
                describeFact: { String(describing: $0) }, isClosing: { _, fact in fact == .finished }))
        facts = try source.attach()
    }
    func producerEnded() { source.end() }
    func hold(_ paneId: PaneId, step: HeldStep<TerminalActivationAdmission>) { holds[paneId] = step }
    func releaseAll() {
        for hold in holds.values { hold.retire() }
        holds.removeAll()
    }
    func installRestoreKinds(_ values: [PaneId: TerminalRestoreKind]) {
        installedKinds.merge(values) { _, latest in latest }
        installations.append(values)
    }
    func recordCurrentVisibleQueuedTerminals(_ terminals: TerminalVisibleQueuedTerminals) -> TerminalVisibilityRevision
    {
        .init(generation: terminals.generation, ordinal: 0)
    }
    func claimPreparedTerminal(_ proposal: TerminalAdmissionProposal) -> TerminalAdmissionClaimOutcome {
        guard let descriptor = descriptors[proposal.paneID] else { return .rejected(.paneNotInCohort) }
        claims.append(proposal.paneID)
        source.sink(proposal.paneID.uuid, .claimed)
        return .claimed(
            .init(
                claimID: UUIDv7.generate(),
                admission: .init(
                    generation: proposal.generation, descriptor: descriptor, attempt: proposal.attempt,
                    restoreKind: installedKinds[proposal.paneID]),
                acknowledgedVisibilityRevision: proposal.appliedVisibilityRevision))
    }
    func activateClaimedTerminal(_ claim: ClaimedTerminalAdmission) async -> ClaimedTerminalActivationOutcome {
        let admission = claim.admission
        let paneId = admission.descriptor.paneID
        admissions.append(admission)
        active += 1
        maximumActive = max(maximumActive, active)
        source.sink(paneId.uuid, .started)
        if let hold = holds[paneId] { try? await hold.arrive(admission) }
        holds[paneId] = nil
        active -= 1
        source.sink(paneId.uuid, .finished)
        return .attempted(.ready(surfaceID: UUIDv7.generate()))
    }
    func expectStart(_ paneId: PaneId) async throws {
        try await facts.expectNext(in: paneId.uuid, .claimed)
        try await facts.expectNext(in: paneId.uuid, .started)
    }
    func expectFinish(_ paneId: PaneId) async throws { try await facts.expectNext(in: paneId.uuid, .finished) }
}

func resumeReadinessDescriptor(priority: TerminalActivationVisibilityPriority = .activeVisible)
    -> TerminalActivationDescriptor
{
    .init(
        pane: Pane(
            id: UUIDv7.generate(),
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(
                launchDirectory: URL(filePath: "/tmp/resume-readiness-proof"), title: "Resume readiness")),
        visibilityPriority: priority, hostPlacement: .tab(tabID: UUIDv7.generate()))
}

func resumeReadinessBasePlan(_ descriptor: TerminalActivationDescriptor) throws -> TerminalColdRestorePlan {
    let session = try #require(descriptor.pane.terminalState?.zmxSessionID)
    return TerminalColdRestorePlan(
        zmxExecutable: URL(fileURLWithPath: "/unused/zmx"),
        zmxDirectory: URL(fileURLWithPath: "/unused/zmx-root"), sessionID: session,
        loginShell: URL(fileURLWithPath: "/bin/zsh"),
        folderCandidates: [URL(fileURLWithPath: "/tmp/resume-readiness-proof")],
        notice: .init(linesByCandidateIndex: ["Restored after restart\nno saved output"]),
        replayFile: nil, resume: nil, attemptID: .generate())
}

@MainActor
func resumeReadinessScheduler(
    entries: [TerminalActivationDescriptor], port: ResumeReadinessAdmissionPort,
    kinds: [PaneId: TerminalRestoreKind], generation: WorkspaceContentMountGeneration = .init()
) async -> TerminalActivationScheduler {
    let scheduler = TerminalActivationScheduler(
        cohort: .init(generation: generation, input: .init(entries: entries)),
        admissionPort: port, requiresRestoreClassification: Set(entries.map(\.paneID)))
    _ = await scheduler.installGeometryEligibility(Set(entries.map(\.paneID)))
    for descriptor in entries { await scheduler.enqueueRestoreKind(kinds[descriptor.paneID], for: descriptor.paneID) }
    return scheduler
}
