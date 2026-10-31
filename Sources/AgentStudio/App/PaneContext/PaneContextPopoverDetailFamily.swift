import AgentStudioInfrastructure
import Foundation
import Synchronization

struct PaneContextPopoverProjectionWork: Sendable {
    let snapshot: PaneContextPopoverSnapshot
    let baselineToken: UInt64?
    let baseline: PopoverDetail?
    let bodyLayouts: PaneContextMessageBodyMeasurement.OpeningLayouts
}
struct PaneContextPopoverProjectionCandidate: Sendable {
    enum Disposition: Sendable {
        case equal(PopoverDetail)
        case changed(PopoverDetail)
    }
    let identity: PaneContextPopoverRequestIdentity
    let baselineToken: UInt64?
    let disposition: Disposition
}

typealias PaneContextPopoverDetailAtom = EagerDerivedAtom<
    PaneContextPopoverSnapshot, PaneContextPopoverRequestIdentity,
    PaneContextPopoverProjectionWork, PaneContextPopoverProjectionCandidate, PopoverDetail
>
typealias PaneContextPopoverMaterializedFamily = EagerDerivedAtomFamily<
    PaneContextPopoverConsumerKey, PaneContextPopoverSnapshot, PaneContextPopoverRequestIdentity,
    PaneContextPopoverProjectionWork, PaneContextPopoverProjectionCandidate, PopoverDetail
>

/// MainActor only materializes slots, captures baseline references and applies prepared dispositions.
@MainActor
final class PaneContextPopoverDetailFamily {
    final class SourceRevision: Sendable {
        private let value = Mutex<UInt64>(0)
        nonisolated var current: UInt64 { value.withLock { $0 } }
        nonisolated func revoke(_ atom: PaneContextPopoverDetailAtom, ifCurrent expected: UInt64? = nil) {
            value.withLock { current in
                guard expected == nil || expected == current else { return }
                current &+= 1
                atom.sourceDidInvalidate()
            }
        }
    }
    struct Slot: Sendable {
        let key: PaneContextPopoverConsumerKey
        let atom: PaneContextPopoverDetailAtom
        let sourceRevision: SourceRevision
        let bodyLayouts = PaneContextMessageBodyMeasurement.OpeningLayouts()

        nonisolated func prepare(_ snapshot: PaneContextPopoverSnapshot) -> Admission {
            .init(snapshot: snapshot, slot: self, sourceRevision: sourceRevision.current)
        }
        nonisolated func invalidate() {
            sourceRevision.revoke(atom)
        }
    }
    struct Admission: Sendable {
        let snapshot: PaneContextPopoverSnapshot
        let slot: Slot
        let sourceRevision: UInt64

        nonisolated func cancel() {
            slot.sourceRevision.revoke(slot.atom, ifCurrent: sourceRevision)
        }
    }

    private struct Baseline {
        let token: UInt64
        let value: PopoverDetail
    }
    private var family: PaneContextPopoverMaterializedFamily!
    private var slots: [PaneContextPopoverConsumerKey: Slot] = [:]
    private var baselines: [PaneContextPopoverConsumerKey: Baseline] = [:]
    private var completionValues: [PaneContextPopoverRequestIdentity: PopoverDetail] = [:]
    private var applyStarts: [PaneContextPopoverRequestIdentity: ContinuousClock.Instant] = [:]
    private var waiters:
        [PaneContextPopoverRequestIdentity: CheckedContinuation<PaneContextPopoverProjectionOutcome, Never>] = [:]
    private var baselineSequence: UInt64 = 0
    private var stopped = false
    private let performance: PaneContextPopoverPerformance
    var textLayoutCount: UInt64 { performance.textLayoutCount }

    init(performance: PaneContextPopoverPerformance = .init(recorder: nil)) {
        self.performance = performance
        family = .init(
            telemetryLabel: "pane_context_popover_detail",
            intentIdentity: { $0.identity }, combinePendingIntents: { _, latest in latest },
            prepare: { [weak self] snapshot, _ in
                guard let self, let slot = self.slots[snapshot.identity.key] else { return .rejected }
                let baseline = self.baselines[snapshot.identity.key]
                return .prepared(
                    .init(
                        snapshot: snapshot, baselineToken: baseline?.token, baseline: baseline?.value,
                        bodyLayouts: slot.bodyLayouts))
            },
            project: { work throws(CancellationError) in
                if Task.isCancelled { throw CancellationError() }
                let candidate: PaneContextPopoverProjectionCandidate = performance.project(
                    key: work.snapshot.identity.key
                ) {
                    let value = PaneContextPopoverDetailProjection.project(
                        work.snapshot, baseline: work.baseline, performance: performance,
                        openingLayouts: work.bodyLayouts)
                    let disposition: PaneContextPopoverProjectionCandidate.Disposition =
                        value.content == work.baseline?.content
                            && value.interactions.versions == work.baseline?.interactions.versions
                            && value.interactions.providerVersions == work.baseline?.interactions.providerVersions
                        ? .equal(value) : .changed(value)
                    return .init(
                        identity: work.snapshot.identity, baselineToken: work.baselineToken, disposition: disposition)
                }
                if Task.isCancelled { throw CancellationError() }
                return candidate
            },
            classify: { [weak self] candidate, _ in self?.classify(candidate) ?? .rejected },
            onProjectionCompletion: { [weak self] _, completion in self?.complete(completion) })
    }

    func materialize(for key: PaneContextPopoverConsumerKey) -> PaneContextPopoverDetailAtom? {
        performance.mainActorHeld(.materialize, key: key) { family.materialize(for: key) }
    }

    func materializedSlot(for key: PaneContextPopoverConsumerKey) -> Slot? {
        guard let atom = materialize(for: key) else { return nil }
        if let existing = slots[key], existing.atom === atom { return existing }
        let slot = Slot(key: key, atom: atom, sourceRevision: .init())
        slots[key] = slot
        return slot
    }

    func projectionPort(for key: PaneContextPopoverConsumerKey) -> PaneContextPopoverProjectionPort? {
        guard let slot = materializedSlot(for: key) else { return nil }
        return .init(
            admit: { [weak self, slot] snapshot in
                guard let self, !Task.isCancelled else { return .cancelled }
                let admission = slot.prepare(snapshot)
                return await withTaskCancellationHandler {
                    await self.admit(admission)
                } onCancel: {
                    admission.cancel()
                }
            },
            invalidate: { slot.invalidate() },
            retire: { [weak self, slot] in
                slot.invalidate()
                await self?.retire(key, atom: slot.atom)
            })
    }

    /// Applies the source-prepared identity after the actor hop; it never adopts a newer source revision.
    func admit(_ admission: Admission) async -> PaneContextPopoverProjectionOutcome {
        let snapshot = admission.snapshot
        let slot = admission.slot
        guard !stopped, !Task.isCancelled, snapshot.identity.key == slot.key, family.atom(for: slot.key) === slot.atom
        else { return .cancelled }
        guard slot.sourceRevision.current == admission.sourceRevision else { return .superseded }
        return await withCheckedContinuation { continuation in
            performance.mainActorHeld(.admit, key: slot.key) {
                precondition(waiters[snapshot.identity] == nil, "A complete projection identity is admitted once")
                waiters[snapshot.identity] = continuation
                performance.record(.familyAdmission, key: slot.key)
                family.admit(snapshot, for: slot.key)
            }
        }
    }

    func classify(_ candidate: PaneContextPopoverProjectionCandidate)
        -> PaneContextPopoverDetailAtom.CandidateDisposition
    {
        let disposition: PaneContextPopoverDetailAtom.CandidateDisposition = performance.mainActorHeld(
            .classify, key: candidate.identity.key
        ) {
            let key = candidate.identity.key
            guard baselines[key]?.token == candidate.baselineToken else { return .rejected }
            let value: PopoverDetail
            let equal: Bool
            switch candidate.disposition {
            case .equal(let prepared):
                value = prepared
                equal = true
            case .changed(let prepared):
                value = prepared
                equal = false
            }
            baselineSequence &+= 1
            baselines[key] = .init(token: baselineSequence, value: value)
            completionValues[candidate.identity] = value
            return equal ? .equalCurrent(value) : .immediateAccepted(value)
        }
        if case .immediateAccepted = disposition, let start = performance.mainActorApplyStarted() {
            // Immediate acceptance commits and calls complete synchronously through AtomLib, with no actor suspension.
            applyStarts[candidate.identity] = start
        }
        return disposition
    }

    private func complete(_ completion: PaneContextPopoverDetailAtom.ProjectionCompletion) {
        let identity: PaneContextPopoverRequestIdentity
        switch completion {
        case .published(let value), .equal(let value), .rejected(let value), .superseded(let value),
            .cancelled(let value):
            identity = value
        }
        if let start = applyStarts.removeValue(forKey: identity) {
            // Covers the actual atom assignment/observation commit and its bounded family bookkeeping.
            performance.mainActorApplyCompleted(since: start, key: identity.key)
        }
        performance.mainActorHeld(.complete, key: identity.key) {
            complete(completion, identity: identity)
        }
    }

    private func complete(
        _ completion: PaneContextPopoverDetailAtom.ProjectionCompletion, identity: PaneContextPopoverRequestIdentity
    ) {
        let value = completionValues.removeValue(forKey: identity)
        guard let continuation = waiters.removeValue(forKey: identity) else { return }
        let outcome: PaneContextPopoverProjectionOutcome
        switch completion {
        case .published:
            if value != nil {
                let stage: PaneContextPopoverPerformance.Stage
                switch identity.producer {
                case .input: stage = .inputPublication
                case .execution: stage = identity.validationPhase == .pending ? .validationPublication : .publication
                }
                performance.record(stage, key: identity.key)
            }
            outcome = value.map { .published($0.metadata) } ?? .superseded
        case .equal:
            performance.record(.equal, key: identity.key)
            outcome = value.map { .equal($0.metadata) } ?? .superseded
        case .rejected, .superseded:
            performance.record(.superseded, key: identity.key)
            outcome = .superseded
        case .cancelled:
            performance.record(.cancelled, key: identity.key)
            outcome = .cancelled
        }
        continuation.resume(returning: outcome)
    }

    private func retire(_ key: PaneContextPopoverConsumerKey, atom: PaneContextPopoverDetailAtom) async {
        guard family.atom(for: key) === atom else { return }
        baselines.removeValue(forKey: key)
        let bodyLayouts = slots.removeValue(forKey: key)?.bodyLayouts
        await family.removeAndDrain(for: key)
        await bodyLayouts?.removeAll()
    }

    func stop() async {
        stopped = true
        let retiringSlots = slots
        await family.stopAndDrain()
        await Self.clearBodyLayouts(in: retiringSlots)
        baselines.removeAll()
        slots.removeAll()
        completionValues.removeAll()
        applyStarts.removeAll()
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: .cancelled) }
    }

    @concurrent nonisolated private static func clearBodyLayouts(in slots: [PaneContextPopoverConsumerKey: Slot]) async
    {
        for slot in slots.values { await slot.bodyLayouts.removeAll() }
    }
}
