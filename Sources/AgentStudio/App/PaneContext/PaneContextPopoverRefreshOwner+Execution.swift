import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension PaneContextPopoverRefreshOwner {
    func execute(
        _ key: PaneContextPopoverConsumerKey, id: UUID, opening: UInt64, epoch: UUID, generation: UInt64,
        kind: PaneContextPopoverOwnerFact.ExecutionKind
    ) async {
        var finish = PaneContextPopoverOwnerFact.Finish.superseded
        defer { finishExecution(key, id: id, outcome: finish) }
        let current = { self.isCurrent(key, opening: opening, epoch: epoch, generation: generation) }
        guard current() else {
            finish = .cancelled
            return
        }
        let capture: PopoverSourceCapture
        let state: PaneContextPopoverSnapshot.State
        var loadedPages: Set<PaneContextPopoverPageScope> = []
        if kind == .age, let consumer = consumers[key], let retainedState = consumer.acceptedState,
            let captured = consumer.capture
        {
            capture = captured
            state = retainedState
            loadedPages = consumer.loadedPages
        } else {
            guard
                let captured = await captureCurrentValues(key, opening: opening, epoch: epoch, generation: generation),
                current()
            else { return }
            capture = captured
            guard let consumer = consumers[key] else { return }
            if let service, !consumer.sourceEnded {
                guard await registerSources(key, service: service, opening: opening, generation: generation), current()
                else { return }
                let versions = await service.invalidations.invalidationGenerations(for: consumer.sources)
                guard current() else { return }
                for (source, version) in versions {
                    sourceGenerations[source] = max(sourceGenerations[source] ?? 0, version)
                }
                guard
                    let assembled = await assemble(
                        .init(
                            key: key, service: service, versions: versions, id: id, opening: opening,
                            generation: generation)),
                    current()
                else { return }
                state = assembled.state
                loadedPages = assembled.pages
            } else {
                state = .unavailable(.databaseUnavailable, retained: consumer.retained)
                observe(.execution(key, id), .readFailed(.databaseUnavailable))
            }
        }
        guard current(), let consumer = consumers[key] else { return }
        let identity = PaneContextPopoverRequestIdentity(
            key: key, openingEpoch: opening, serviceEpoch: epoch, requestGeneration: generation,
            inputGeneration: consumer.inputGeneration, ageGeneration: consumer.ageGeneration,
            pageGeneration: consumer.pageGeneration)
        let snapshot = PaneContextPopoverSnapshot(
            identity: identity, demand: consumer.demand, capture: capture, state: state, wallNow: wallNow(),
            frozenWidth: consumer.frozenWidth ?? preferredWidth(for: consumer.demand, state: state))
        let outcome = await consumer.projection.admit(snapshot)
        guard current(), var accepted = consumers[key] else { return }
        observe(.execution(key, id), .projected)
        switch outcome {
        case .published(let metadata), .equal(let metadata):
            accepted.nextAgeBoundary = metadata.nextAgeBoundary
            if case .ready = state { accepted.frozenWidth = metadata.openingWidth }
            accepted.loadedPages = loadedPages
            accepted.acceptedState = state
            let completedScopes: Set<PaneContextPopoverPageScope>
            let pageOutcome: PaneContextPopoverOwnerFact.PageFinish
            switch state {
            case .ready:
                completedScopes = loadedPages
                pageOutcome = .loaded
            case .unavailable(let failure, _):
                completedScopes = Set(accepted.pendingPages.keys)
                pageOutcome = .unavailable(failure)
            case .paneGone:
                completedScopes = Set(accepted.pendingPages.keys)
                pageOutcome = .paneGone
            }
            for scope in completedScopes {
                for request in accepted.pendingPages.removeValue(forKey: scope) ?? [] {
                    observe(.page(request), .pageFinished(pageOutcome))
                }
            }
            consumers[key] = accepted
            if case .published = outcome {
                observe(.execution(key, id), .published)
                finish = .published
            } else {
                observe(.execution(key, id), .equal)
                finish = .equal
            }
        case .superseded:
            observe(.execution(key, id), .superseded)
        case .cancelled:
            observe(.execution(key, id), .cancelled)
            finish = .cancelled
        }
    }

    func captureCurrentValues(
        _ key: PaneContextPopoverConsumerKey, opening: UInt64, epoch: UUID, generation: UInt64
    ) async -> PopoverSourceCapture? {
        guard let initial = consumers[key] else { return nil }
        var requested = initial.sources
        while isCurrent(key, opening: opening, epoch: epoch, generation: generation) {
            let captured = await captureValues(key, opening, requested)
            guard isCurrent(key, opening: opening, epoch: epoch, generation: generation), var consumer = consumers[key]
            else { return nil }
            guard captured.serviceEpoch == service?.epoch else {
                receive(captured, for: key, opening: opening)
                return nil
            }
            if consumer.capture?.sources != captured.sources { consumer.inputGeneration &+= 1 }
            if captured.observationGeneration >= (consumer.capture?.observationGeneration ?? 0) {
                consumer.capture = captured
            }
            let owner = captured.sources[key.paneId]?.structuralFacts
            let desired: Set<PaneId>
            if consumer.demand.includingDrawers, owner?.isDrawerChild != true {
                desired = Set([key.paneId] + (owner?.ownedDrawerPaneIDs ?? []).map { PaneId(existingUUID: $0) })
            } else {
                desired = [key.paneId]
            }
            consumer.sources = desired
            consumers[key] = consumer
            if desired == requested { return captured }
            requested = desired
        }
        return nil
    }

    func registerSources(
        _ key: PaneContextPopoverConsumerKey, service: PaneContextPopoverServicePorts,
        opening: UInt64, generation: UInt64
    ) async -> Bool {
        guard var consumer = consumers[key] else { return false }
        if let current = consumer.sourceObservation,
            current.serviceEpoch == service.epoch, current.sources == consumer.sources
        {
            return true
        }
        let previous = consumer.sourceObservation
        consumer.sourceObservation = nil
        consumers[key] = consumer
        previous?.task.cancel()
        await previous?.task.value
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return false }
        let sources = consumer.sources
        let stream = await service.invalidations.invalidations(for: sources)
        let task = Task<Void, Never> { [weak self] in
            for await change in stream {
                guard !Task.isCancelled else { return }
                await self?.sourceInvalidated(change, epoch: service.epoch)
            }
            guard !Task.isCancelled else { return }
            await self?.sourceEnded(key, opening: opening, epoch: service.epoch)
        }
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation),
            var latest = consumers[key]
        else {
            task.cancel()
            await task.value
            return false
        }
        latest.sourceObservation = .init(sources: sources, serviceEpoch: service.epoch, task: task)
        consumers[key] = latest
        return true
    }

    func validateVersions(
        _ versions: [PaneId: UInt64], key: PaneContextPopoverConsumerKey,
        service: PaneContextPopoverServicePorts, opening: UInt64, generation: UInt64
    ) async -> Bool {
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return false }
        let current = await service.invalidations.invalidationGenerations(for: Set(versions.keys))
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return false }
        guard current == versions else {
            for (source, version) in current {
                mergeSourceGeneration(source, generation: version, epoch: service.epoch)
            }
            return false
        }
        guard let consumer = consumers[key] else { return false }
        let captured = await captureValues(key, opening, consumer.sources)
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return false }
        guard captured.serviceEpoch == service.epoch, captured.sources == consumers[key]?.capture?.sources else {
            receive(captured, for: key, opening: opening)
            return false
        }
        if var latest = consumers[key], captured.observationGeneration >= (latest.capture?.observationGeneration ?? 0) {
            latest.capture = captured
            consumers[key] = latest
        }
        return true
    }

    func preferredWidth(for demand: PaneContextPopoverDemand, state: PaneContextPopoverSnapshot.State) -> Double {
        if case .agentLine = demand.content { return Double(AppStyles.Components.PaneContext.popoverWidth) }
        let multiline: Bool
        if case .ready(.detail(let detail, _)) = state {
            multiline =
                (detail.messages + detail.drawerMessages.flatMap(\.messages)).contains {
                    $0.body.contains(where: \.isNewline)
                }
                || detail.scopedSessions.contains { source in
                    source.session?.providerPrompts.contains { $0.summary?.contains(where: \.isNewline) == true }
                        == true
                }
        } else {
            multiline = false
        }
        let preferred =
            multiline
            ? AppStyles.Components.PaneContext.messagesPopoverMaximumWidth
            : AppStyles.Components.PaneContext.messagesPopoverIdealWidth
        return min(
            max(0, demand.screenVisibleWidth - 2 * Double(AppStyles.Components.PaneContext.popoverScreenInset)),
            max(Double(AppStyles.Components.PaneContext.messagesPopoverMinimumWidth), Double(preferred)))
    }
}
