import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension PaneContextPopoverRefreshOwner {
    func rescheduleDeadline() {
        let now = clock.now
        let wall = wallNow()
        let next =
            stopping
            ? nil
            : consumers.values.compactMap { consumer -> SourceClock.Instant? in
                guard consumer.execution == nil else { return nil }
                let eligible =
                    consumer.lastAdmission?.advanced(by: AppPolicies.PaneContext.backgroundRefreshMinimumSpacing)
                    ?? now
                if consumer.pending != nil { return max(now, eligible) }
                guard let age = consumer.nextAgeBoundary else { return nil }
                return max(eligible, now.advanced(by: .seconds(max(0, age.timeIntervalSince(wall)))))
            }.min()
        guard next != scheduledDeadline else { return }
        let previous = deadlineTask
        previous?.cancel()
        scheduledDeadline = next
        deadlineSequence &+= 1
        let sequence = deadlineSequence
        guard let next else {
            deadlineTask = previous.map { task in Task { await task.value } }
            return
        }
        let clock = clock
        observe(.deadline(sequence), .deadlineArmed)
        deadlineTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else {
                await self?.deadlineEnded(sequence, cancelled: true)
                return
            }
            do { try await clock.sleep(until: next, tolerance: nil) } catch {
                await self?.deadlineEnded(sequence, cancelled: true)
                return
            }
            await self?.deadlineEnded(sequence, cancelled: Task.isCancelled)
        }
    }

    func deadlineEnded(_ sequence: UInt64, cancelled: Bool) {
        observe(.deadline(sequence), .deadlineEnded(cancelled: cancelled))
        guard sequence == deadlineSequence, !cancelled, !stopping else { return }
        deadlineTask = nil
        scheduledDeadline = nil
        let now = clock.now
        let wall = wallNow()
        for key in Array(consumers.keys) {
            guard let consumer = consumers[key], consumer.execution == nil else { continue }
            let eligible =
                consumer.lastAdmission?.advanced(by: AppPolicies.PaneContext.backgroundRefreshMinimumSpacing)
                ?? now
            guard now >= eligible else { continue }
            if consumer.pending != nil {
                startIfEligible(key)
            } else if let boundary = consumer.nextAgeBoundary, boundary <= wall {
                enqueue(key, kind: .age)
            }
        }
        rescheduleDeadline()
    }

    func sourceInvalidated(
        _ change: PaneContextSourceInvalidation, epoch: UUID
    ) {
        mergeSourceGeneration(change.sourcePaneId, generation: change.generation, epoch: epoch)
    }

    func mergeSourceGeneration(_ source: PaneId, generation: UInt64, epoch: UUID) {
        guard !stopping, epoch == serviceEpoch, generation > (sourceGenerations[source] ?? 0) else { return }
        sourceGenerations[source] = generation
        for key in Array(consumers.keys) {
            guard let consumer = consumers[key], consumer.sources.contains(source) else { continue }
            observe(.consumer(key, opening: consumer.opening), .observed)
            enqueue(key, kind: .background)
        }
        rescheduleDeadline()
    }

    func sourceEnded(_ key: PaneContextPopoverConsumerKey, opening: UInt64, epoch: UUID) {
        guard !stopping, epoch == serviceEpoch, var consumer = consumers[key], consumer.opening == opening else {
            return
        }
        consumer.sourceEnded = true
        consumers[key] = consumer
        enqueue(key, kind: .action)
        rescheduleDeadline()
    }
}
