import AgentStudioCore
import AgentStudioTerminal
import Foundation

struct ColdResumePlanRequest: Sendable {
    let paneID: PaneId
    let plan: TerminalColdRestorePlan
    let inventory: ZmxSessionInventory
}

extension AppDelegate {
    func retireColdResumePane(_ paneID: UUID) async {
        await installedWorkspacePreparedContentMountOwners.coordinator.retireAwaitingResumeReadiness(
            .init(existingUUID: paneID))
    }

    func makeColdResumePlanResolution() -> ColdResumePlanResolution {
        let readiness = restoreResumeReadiness
        let launchBoot = restoreLaunchBoot
        return { [weak self] paneID, plan, inventory in
            await Self.resolveColdResumePlan(
                request: .init(paneID: paneID, plan: plan, inventory: inventory),
                readiness: readiness, launchBoot: launchBoot,
                decision: { [weak self] finalRead in await self?.coldResumeDecision(needsFinalRead: finalRead) })
        }
    }

    @concurrent nonisolated static func resolveColdResumePlan<ResumeClock: Clock<Duration>>(
        request: ColdResumePlanRequest,
        readiness: RestoreResumeReadiness<ResumeClock>,
        launchBoot: TerminalRestoreLaunchBoot?,
        decision: @MainActor @Sendable (Bool) async -> ColdRestoreResumeDecision?
    ) async -> TerminalColdRestorePlan {
        let readState = await readiness.wait(paneId: request.paneID.uuid)
        guard let owner = await decision(readState == .ready && launchBoot?.isSameBoot == true) else {
            return TerminalColdRestorePlanBuilder.applyingUncheckedAgentStateNotice(to: request.plan)
        }
        let result = await owner.resolve(
            paneId: request.paneID.uuid, sessionId: request.plan.sessionID,
            readiness: readState, launchBoot: launchBoot, inventory: request.inventory)
        return result.applying(to: request.plan)
    }

    private func coldResumeDecision(needsFinalRead: Bool) async -> ColdRestoreResumeDecision? {
        guard let ingestion = appIPCSessionsPaneContextComposition?.ingestion,
            let foreground = restoreForegroundEvidenceRepository
        else { return nil }
        let storeURL = appIPCPaths?.cliStoreURL
        let task = paneCLIOutboxDrainTask
        let drain = needsFinalRead ? await task?.value : nil
        return .init(
            ingestion: ingestion, foregroundRepository: foreground, drain: drain, storeURL: storeURL,
            performanceTraceRecorder: performanceTraceRecorder)
    }
}
