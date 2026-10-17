import AgentStudioInfrastructure

struct RepoExplorerPendingMaterializationSettlement {
    let token: RepoExplorerMaterializedProjection.CandidateToken
    let materializationCandidate: RepoExplorerMaterializationCandidate
    let work: RepoExplorerProjectionWork
    let proposedValue: RepoExplorerProjectionResult
    let previousPublishedResult: RepoExplorerProjectionResult?

    var candidateID: RepoExplorerMaterializationCandidateID {
        materializationCandidate.id
    }
}

struct RepoExplorerAcknowledgedBaselineIdentity: Equatable {
    let lifetimeID: RepoExplorerMaterializationHostLifetimeID
    let demandEpoch: UInt64
    let revision: UInt64

    init(_ baseline: RepoExplorerMaterializationBaseline) {
        lifetimeID = baseline.lifetimeID
        demandEpoch = baseline.demandEpoch
        revision = baseline.revision
    }
}

extension RepoExplorerProjectionAdapter {
    func prepareProjectionWork(
        _ intent: RepoExplorerProjectionIntent
    ) -> RepoExplorerMaterializedProjection.PreparationDisposition {
        let request = intent.targetRequest
        guard !hasStopped,
            request.generation == projectionGeneration,
            request.generation == cachedProjectionRequest?.generation
        else {
            return .rejected
        }
        guard let materializationHost,
            let acknowledgedMaterializationBaseline,
            acknowledgedMaterializationBaseline.lifetimeID == materializationHost.lifetimeID,
            acknowledgedMaterializationBaseline.demandEpoch == materializationDemandEpoch
        else {
            return .rejected
        }

        let context = RepoExplorerProjectionWorkContext(
            demandEpoch: materializationDemandEpoch,
            requestGeneration: request.generation,
            semanticBaselineSequence: semanticBaselineSequence,
            semanticBaselineResult: semanticBaselineResult,
            acknowledgedBaseline: acknowledgedMaterializationBaseline
        )
        switch intent {
        case .full:
            return .prepared(
                .full(RepoExplorerFullProjectionWork(targetRequest: request, context: context))
            )
        case .delta(let deltaIntent):
            guard semanticBaselineResult != nil else {
                return .prepared(
                    .full(RepoExplorerFullProjectionWork(targetRequest: request, context: context))
                )
            }
            return .prepared(
                .delta(
                    RepoExplorerDeltaProjectionWork(
                        targetRequest: request,
                        changes: deltaIntent.changes,
                        structuralTarget: deltaIntent.structuralTarget,
                        context: context
                    )
                )
            )
        }
    }

    func classifyProjectionCandidate(
        _ candidate: RepoExplorerProjectionCandidate
    ) -> RepoExplorerMaterializedProjection.CandidateDisposition {
        let result = candidate.result
        let context = candidate.work.context
        guard !hasStopped,
            context.requestGeneration == projectionGeneration,
            context.semanticBaselineSequence == semanticBaselineSequence,
            result.semanticBaselineSequence == nil
                || result.semanticBaselineSequence == context.semanticBaselineSequence,
            result.generation == projectionGeneration,
            result.generation == cachedProjectionRequest?.generation
        else {
            return .rejected
        }

        guard let materializationHost,
            let acknowledgedMaterializationBaseline,
            acknowledgedMaterializationBaseline.lifetimeID == materializationHost.lifetimeID,
            acknowledgedMaterializationBaseline.demandEpoch == materializationDemandEpoch
        else {
            return .rejected
        }

        guard let nativeUpdatePlan = candidate.nativeUpdatePlan,
            nativeUpdatePlan.preflightMatches(
                baseline: acknowledgedMaterializationBaseline,
                requestGeneration: UInt64(context.requestGeneration)
            )
        else {
            return .rejected
        }

        if case .equal = nativeUpdatePlan.kind {
            return .equalCurrent(result)
        }
        if let preparedBaseline = context.acknowledgedBaseline,
            RepoExplorerAcknowledgedBaselineIdentity(preparedBaseline)
                == RepoExplorerAcknowledgedBaselineIdentity(acknowledgedMaterializationBaseline),
            preparedBaseline.lifetimeID == materializationHost.lifetimeID,
            preparedBaseline.demandEpoch == materializationDemandEpoch,
            case .changed = nativeUpdatePlan.kind
        {
            return .changedAwaitingOwner(result)
        }

        return .rejected
    }

    func applyAwaitingProjectionCandidate(
        token: RepoExplorerMaterializedProjection.CandidateToken,
        candidate: RepoExplorerProjectionCandidate,
        proposedValue: RepoExplorerProjectionResult
    ) {
        guard pendingMaterializationSettlement == nil,
            let host = materializationHost,
            let baseline = acknowledgedMaterializationBaseline,
            candidate.work.context.acknowledgedBaseline.map(RepoExplorerAcknowledgedBaselineIdentity.init)
                == RepoExplorerAcknowledgedBaselineIdentity(baseline),
            let nativeUpdatePlan = candidate.nativeUpdatePlan,
            nativeUpdatePlan.preflightMatches(
                baseline: baseline,
                requestGeneration: UInt64(candidate.work.context.requestGeneration)
            ),
            case .changed(let changedPlan) = nativeUpdatePlan.kind
        else {
            _ = materializedProjection?.settle(token, .rejected)
            return
        }

        nextMaterializationCandidateID &+= 1
        let candidateID = RepoExplorerMaterializationCandidateID(
            rawValue: nextMaterializationCandidateID
        )
        let hostCandidate = RepoExplorerMaterializationCandidate(
            id: candidateID,
            lifetimeID: baseline.lifetimeID,
            demandEpoch: baseline.demandEpoch,
            requestGeneration: UInt64(candidate.work.context.requestGeneration),
            visibleGeneration: UInt64(proposedValue.generation),
            expectedRevision: changedPlan.preflight.oldRevision,
            proposedRevision: changedPlan.proposedRevision,
            presentation: candidate.materializationPresentation,
            nativeUpdatePlan: nativeUpdatePlan
        )
        let pending = RepoExplorerPendingMaterializationSettlement(
            token: token,
            materializationCandidate: hostCandidate,
            work: candidate.work,
            proposedValue: proposedValue,
            previousPublishedResult: publishedResult
        )
        pendingMaterializationSettlement = pending
        publishedResult = proposedValue

        let disposition = host.apply(hostCandidate)
        guard pendingMaterializationSettlement?.candidateID == candidateID else { return }
        switch disposition {
        case .accepted(let acceptedBaseline):
            receiveMaterializationFeedback(
                .accepted(identity: .candidate(candidateID), baseline: acceptedBaseline)
            )
        case .rejected(let reason):
            receiveMaterializationFeedback(.rejected(candidateID: candidateID, reason: reason))
        case .equal:
            pendingMaterializationSettlement = nil
            _ = materializedProjection?.settle(token, .accepted(proposedValue))
        }
    }

    @discardableResult
    func registerMaterializationHost(_ host: RepoExplorerMaterializationHost) -> Bool {
        guard !hasStopped,
            materializationHost == nil || materializationHost === host,
            host.isPresentationReady,
            let baseline = host.acceptedBaseline,
            baseline.lifetimeID == host.lifetimeID,
            baseline.demandEpoch == materializationDemandEpoch
        else {
            return false
        }
        materializationHost = host
        acknowledgedMaterializationBaseline = baseline
        lastRecoveryBaselineIdentity = nil
        materializationHostDidRegister()
        return true
    }

    func unregisterMaterializationHost(lifetimeID: RepoExplorerMaterializationHostLifetimeID) {
        guard materializationHost?.lifetimeID == lifetimeID else { return }
        rejectPendingMaterializationSettlement()
        materializationHost = nil
        acknowledgedMaterializationBaseline = nil
        materializedProjection?.sourceDidInvalidate()
    }

    func receiveMaterializationFeedback(_ feedback: RepoExplorerMaterializationFeedback) {
        switch feedback {
        case .accepted(let identity, let baseline):
            guard let materializationHost,
                baseline.lifetimeID == materializationHost.lifetimeID,
                baseline.demandEpoch == materializationDemandEpoch
            else {
                return
            }
            switch identity {
            case .initial, .reentry:
                guard
                    materializationHost.acceptedBaseline.map(RepoExplorerAcknowledgedBaselineIdentity.init)
                        == RepoExplorerAcknowledgedBaselineIdentity(baseline)
                else { return }
                acknowledgedMaterializationBaseline = baseline
                lastRecoveryBaselineIdentity = nil
            case .candidate(let candidateID):
                guard let pending = pendingMaterializationSettlement,
                    pending.candidateID == candidateID,
                    materializationHost.acceptedBaseline.map(RepoExplorerAcknowledgedBaselineIdentity.init)
                        == RepoExplorerAcknowledgedBaselineIdentity(baseline)
                else {
                    return
                }
                pendingMaterializationSettlement = nil
                acknowledgedMaterializationBaseline = baseline
                lastRecoveryBaselineIdentity = nil
                RepoExplorerPerformanceTelemetry.shared.record(
                    stage: "materialize",
                    outcome: "materialized"
                )
                _ = materializedProjection?.settle(
                    pending.token,
                    .accepted(pending.proposedValue)
                )
            }
        case .rejected(let candidateID, _):
            guard let pending = pendingMaterializationSettlement,
                pending.candidateID == candidateID
            else {
                return
            }
            pendingMaterializationSettlement = nil
            publishedResult = pending.previousPublishedResult
            _ = materializedProjection?.settle(pending.token, .rejected)
            if let acknowledgedMaterializationBaseline {
                let rejectedBaselineIdentity = RepoExplorerAcknowledgedBaselineIdentity(
                    acknowledgedMaterializationBaseline
                )
                guard lastRecoveryBaselineIdentity != rejectedBaselineIdentity else { return }
                lastRecoveryBaselineIdentity = rejectedBaselineIdentity
                rearmFullProjection(after: pending)
            }
        }
    }

    func handleProjectionCompletion(
        _ completion: RepoExplorerMaterializedProjection.ProjectionCompletion
    ) {
        guard let result = projectionFamily.latestAcceptedValue(for: .sidebar) else { return }
        switch completion {
        case .published, .equal:
            guard
                result.semanticBaselineSequence == nil
                    || result.semanticBaselineSequence == semanticBaselineSequence,
                result.generation == projectionGeneration,
                result.generation == cachedProjectionRequest?.generation
            else {
                RepoExplorerPerformanceTelemetry.shared.record(
                    stage: "mainactor_apply",
                    outcome: "superseded"
                )
                return
            }
            let previousSemanticBaselineResult = semanticBaselineResult
            semanticBaselineSequence &+= 1
            semanticBaselineResult = result
            if case .published = completion {
                publishedRevision += 1
                publishedResult = result
                scheduleRecencyDeadline(for: result)
            } else if publishedResult == nil {
                publishedRevision += 1
                publishedResult = result
                scheduleRecencyDeadline(for: result)
            } else {
                if result.movesPresentationTransitions(from: previousSemanticBaselineResult) {
                    scheduleRecencyDeadline(for: result)
                }
                onProjectionSuppressed(result)
            }
        case .rejected, .superseded, .cancelled:
            break
        }
    }

    func suspendMaterializationDemand() {
        guard !isMaterializationDemandSuspended else { return }
        isMaterializationDemandSuspended = true
        materializationDemandEpoch &+= 1
        rejectPendingMaterializationSettlement()
        materializationHost?.suspendDemand()
        acknowledgedMaterializationBaseline = nil
        materializedProjection?.sourceDidInvalidate()
    }

    func resumeRegisteredMaterializationHostIfNeeded() {
        isMaterializationDemandSuspended = false
        guard let host = materializationHost else { return }
        if let baseline = host.acceptedBaseline,
            baseline.demandEpoch == materializationDemandEpoch,
            host.isPresentationReady
        {
            acknowledgedMaterializationBaseline = baseline
            return
        }
        acknowledgedMaterializationBaseline = host.reacknowledgeRetainedPresentation(
            demandEpoch: materializationDemandEpoch
        )
    }

    private func rejectPendingMaterializationSettlement() {
        guard let pending = pendingMaterializationSettlement else { return }
        pendingMaterializationSettlement = nil
        publishedResult = pending.previousPublishedResult
        _ = materializedProjection?.settle(pending.token, .rejected)
    }

    private func rearmFullProjection(after pending: RepoExplorerPendingMaterializationSettlement) {
        guard !hasStopped,
            inputCapture == nil || isDemanded,
            cachedProjectionRequest?.generation == pending.proposedValue.generation
        else {
            return
        }
        projectionGeneration += 1
        let request = pending.work.targetRequest.generated(
            generation: projectionGeneration,
            trigger: .dataRefresh
        )
        cachedProjectionRequest = request
        projectionFamily.admit(.full(request), for: .sidebar)
    }
}
