import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension PaneContextPopoverRefreshOwner {
    struct InputCompletion {
        let key: PaneContextPopoverConsumerKey
        let opening: UInt64
        var waiters: [CheckedContinuation<Void, Never>]
    }

    func awaitInputCompletion(_ operation: UUID, key: PaneContextPopoverConsumerKey, opening: UInt64) async {
        guard let consumer = consumers[key], consumer.opening == opening, consumer.inputOperation == operation else {
            return
        }
        await withCheckedContinuation { continuation in
            if inputCompletions[operation] == nil {
                inputCompletions[operation] = .init(key: key, opening: opening, waiters: [])
            }
            inputCompletions[operation]?.waiters.append(continuation)
        }
    }

    private func completeInput(_ operation: UUID) {
        guard let completion = inputCompletions.removeValue(forKey: operation) else { return }
        for waiter in completion.waiters { waiter.resume() }
    }

    func retireInputCompletions(for key: PaneContextPopoverConsumerKey, opening: UInt64) {
        let retiring = inputCompletions.compactMap { operation, completion in
            completion.key == key && completion.opening == opening ? operation : nil
        }
        for operation in retiring { completeInput(operation) }
    }

    enum InputCause: Equatable, Sendable { case canonical, serviceReplacement }
    struct InputApplication {
        let operation: UUID
        let key: PaneContextPopoverConsumerKey
        let opening: UInt64
        let epoch: UUID
        let generation: UInt64
        let previousCapture: PopoverSourceCapture?
        let previousExecution: Execution?
        let cause: InputCause
    }

    func receive(_ capture: PopoverSourceCapture, for key: PaneContextPopoverConsumerKey, opening: UInt64) async {
        guard !stopping, var consumer = consumers[key], consumer.opening == opening else { return }
        guard capture.observationGeneration >= (consumer.capture?.observationGeneration ?? 0) else { return }
        if consumer.capture?.serviceEpoch == capture.serviceEpoch, consumer.capture?.sources == capture.sources {
            consumer.capture = capture
            consumers[key] = consumer
            let operation = UUIDv7.generate()
            observe(.input(operation), .coalesced)
            observe(.input(operation), .inputFinished)
            return
        }
        guard let input = beginInput(key, opening: opening, kind: .background, cause: .canonical) else { return }
        await applyInput(capture, context: input)
    }

    func beginInput(
        _ key: PaneContextPopoverConsumerKey, opening: UInt64,
        kind: PaneContextPopoverOwnerFact.ExecutionKind, cause: InputCause
    ) -> InputApplication? {
        guard !stopping, var consumer = consumers[key], consumer.opening == opening else { return nil }
        let operation = UUIDv7.generate()
        let previousCapture = consumer.capture
        consumer.inputOperation = operation
        consumer.inputGeneration &+= 1
        consumers[key] = consumer
        let previous = reserveRequest(key, kind: kind)
        guard let reserved = consumers[key] else { return nil }
        rescheduleDeadline()
        return .init(
            operation: operation, key: key, opening: opening, epoch: serviceEpoch,
            generation: reserved.requestGeneration, previousCapture: previousCapture,
            previousExecution: previous, cause: cause)
    }

    func applyInput(_ initial: PopoverSourceCapture, context: InputApplication) async {
        defer { finishInput(context) }
        guard let capture = await reconcileInput(initial, context: context),
            isCurrent(context.key, opening: context.opening, epoch: context.epoch, generation: context.generation),
            var consumer = consumers[context.key]
        else {
            observe(.input(context.operation), .superseded)
            return
        }
        let serviceMismatch = capture.serviceEpoch != service?.epoch
        let serviceChanged =
            context.cause == .serviceReplacement
            || context.previousCapture?.serviceEpoch != capture.serviceEpoch
        let critical = consumer.demand.content == .card && (serviceChanged || serviceMismatch)
        consumer.capture = capture
        consumer.sources = Set(canonicalSources(capture, key: context.key, demand: consumer.demand))
        if serviceMismatch {
            consumer.pending = nil
            consumer.nextAgeBoundary = nil
        }
        if serviceChanged { consumer.liveSession = nil }
        consumers[context.key] = consumer
        observe(.input(context.operation), .observed)
        if critical {
            let identity = PaneContextPopoverRequestIdentity(
                key: context.key, openingEpoch: context.opening,
                serviceEpoch: context.epoch, requestGeneration: context.generation,
                inputGeneration: consumer.inputGeneration, ageGeneration: consumer.ageGeneration,
                pageGeneration: consumer.pageGeneration, producer: .input(context.operation), validationPhase: .pending)
            let applied = await publishPendingCard(
                identity, capture: capture,
                shellExecutablePath: consumer.shellExecutablePath, clearingService: serviceChanged || serviceMismatch)
            guard applied else {
                observe(.input(context.operation), .superseded)
                return
            }
        }
        // The input producer may itself be the old read. Its clear has applied before cancellation.
        context.previousExecution?.task.cancel()
    }

    private func reconcileInput(_ initial: PopoverSourceCapture, context: InputApplication) async
        -> PopoverSourceCapture?
    {
        var captured = initial
        while isCurrent(context.key, opening: context.opening, epoch: context.epoch, generation: context.generation) {
            guard let consumer = consumers[context.key] else { return nil }
            let desired = Set(canonicalSources(captured, key: context.key, demand: consumer.demand))
            if desired == Set(captured.sources.keys) { return captured }
            captured = await captureValues(context.key, context.opening, context.generation, desired)
        }
        return nil
    }

    private func finishInput(_ context: InputApplication) {
        if var consumer = consumers[context.key], consumer.opening == context.opening,
            consumer.inputOperation == context.operation
        {
            consumer.inputOperation = nil
            consumers[context.key] = consumer
            startIfEligible(context.key)
            rescheduleDeadline()
        }
        observe(.input(context.operation), .inputFinished)
        completeInput(context.operation)
    }
}
