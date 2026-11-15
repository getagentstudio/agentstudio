import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

extension PaneContextPopoverRefreshOwner {
    struct PersonCommand {
        let id: UUID
        let key: PaneContextPopoverConsumerKey
        let opening: UInt64
        let epoch: UUID
        let service: PaneContextPopoverServicePorts
        let intent: PaneContextPopoverPersonIntent
    }
    struct PersonContext {
        let snapshot: PaneContextActionSnapshot
        let location: PaneContextPopoverLocation
        let includingDrawers: Bool
    }

    func performPerson(
        _ intent: PaneContextPopoverPersonIntent, for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) async -> PaneContextPopoverPersonCompletion {
        let id = UUIDv7.generate()
        guard !stopping, var consumer = consumers[key], consumer.opening == opening, let service else {
            return .init(id: id, resolution: .refused(.openingRetired), presentation: .openingRetired)
        }
        consumer.latestPersonCommand = id
        consumers[key] = consumer
        let command = PersonCommand(
            id: id, key: key, opening: opening, epoch: serviceEpoch, service: service, intent: intent)
        let task = Task { await self.executePerson(command) }
        personTasks[id] = task
        let result = await task.value
        personTasks.removeValue(forKey: id)
        return result
    }

    func personIsCurrent(_ command: PersonCommand) -> Bool {
        !stopping && serviceEpoch == command.epoch && consumers[command.key]?.opening == command.opening
    }

    func personContext(_ command: PersonCommand) async -> PersonContext? {
        guard personIsCurrent(command), let initial = consumers[command.key] else { return nil }
        var requested = initial.sources
        while personIsCurrent(command) {
            guard let captureGeneration = consumers[command.key]?.requestGeneration else { return nil }
            let captured = await captureValues(command.key, command.opening, captureGeneration, requested)
            guard personIsCurrent(command), captured.serviceEpoch == command.service.epoch else { return nil }
            await receive(captured, for: command.key, opening: command.opening)
            guard var consumer = consumers[command.key], let current = consumer.capture else { return nil }
            let owner = current.sources[command.key.paneId]?.structuralFacts
            let desired: Set<PaneId>
            if consumer.demand.includingDrawers, owner?.isDrawerChild != true {
                desired = Set([command.key.paneId] + (owner?.ownedDrawerPaneIDs ?? []).map { PaneId(existingUUID: $0) })
            } else {
                desired = [command.key.paneId]
            }
            consumer.sources = desired
            consumers[command.key] = consumer
            if requested != desired {
                requested = desired
                continue
            }
            if let target = command.intent.messageKey, !desired.contains(target.paneId) { return nil }
            let snapshot: PaneContextActionSnapshot
            if case .card = consumer.demand.content {
                snapshot = .card
            } else if case .detail(let detail) = consumer.retained {
                snapshot = .messages(detail)
            } else {
                snapshot = .messages(nil)
            }
            return .init(
                snapshot: snapshot, location: consumer.demand.location,
                includingDrawers: consumer.demand.includingDrawers)
        }
        return nil
    }

    func executePerson(_ command: PersonCommand) async -> PaneContextPopoverPersonCompletion {
        guard let context = await personContext(command) else {
            return .init(id: command.id, resolution: .refused(.openingRetired), presentation: .openingRetired)
        }
        if let refusal = cardRequestRefusal(context, command: command) { return refusal }
        let resolution: PaneContextPopoverPersonCompletion.Resolution
        switch command.intent {
        case .answer(let key, let draft):
            let parsed = await PaneContextPopoverAnswerParsing.parse(
                messageId: key.messageId, source: key.paneId, snapshot: context.snapshot, draft: draft)
            switch parsed {
            case .failure(let refusal): resolution = .answer(.refused(refusal))
            case .success(let value):
                let presentation = await PaneContextPopoverAnswerParsing.answerPresentation(
                    messageId: key.messageId, source: key.paneId, snapshot: context.snapshot, location: context.location
                )
                guard let current = await personContext(command) else { return retiredPerson(command) }
                if let refusal = cardRequestRefusal(current, command: command) { return refusal }
                let currentPresentation = await PaneContextPopoverAnswerParsing.answerPresentation(
                    messageId: key.messageId, source: key.paneId, snapshot: current.snapshot, location: current.location
                )
                guard personIsCurrent(command) else { return retiredPerson(command) }
                if presentation != .inline || currentPresentation != .inline {
                    resolution = .refused(.answerInMessages)
                } else {
                    resolution = .answer(
                        await command.service.person.answer(
                            .init(messageId: key.messageId, paneId: key.paneId, by: .localUser, value: value)))
                }
            }
        case .dismiss(let key):
            let permitted = await PaneContextPopoverAnswerParsing.canDismiss(
                messageId: key.messageId, source: key.paneId, snapshot: context.snapshot, location: context.location)
            guard let current = await personContext(command) else { return retiredPerson(command) }
            if let refusal = cardRequestRefusal(current, command: command) { return refusal }
            let stillPermitted = await PaneContextPopoverAnswerParsing.canDismiss(
                messageId: key.messageId, source: key.paneId, snapshot: current.snapshot, location: current.location)
            guard personIsCurrent(command) else { return retiredPerson(command) }
            resolution =
                permitted && stillPermitted
                ? .dismiss(await command.service.person.dismiss(messageId: key.messageId, paneId: key.paneId))
                : .refused(.dismissNotAvailable)
        case .runAction(let key, let model):
            let permitted = await PaneContextPopoverAnswerParsing.canRunAction(
                messageId: key.messageId, source: key.paneId, snapshot: context.snapshot, location: context.location)
            let action = await PaneContextPopoverHostActions.coreAction(model)
            guard let current = await personContext(command) else { return retiredPerson(command) }
            if let refusal = cardRequestRefusal(current, command: command) { return refusal }
            let stillPermitted = await PaneContextPopoverAnswerParsing.canRunAction(
                messageId: key.messageId, source: key.paneId, snapshot: current.snapshot, location: current.location)
            guard personIsCurrent(command) else { return retiredPerson(command) }
            if permitted, stillPermitted, let action {
                resolution = .action(
                    await command.service.person.runAction(
                        .init(messageId: key.messageId, paneId: key.paneId, action: action)))
            } else {
                resolution = .refused(.actionNotAvailable)
            }
        case .dismissAllNotices:
            guard personIsCurrent(command) else { return retiredPerson(command) }
            resolution = .dismissAll(
                await command.service.person.dismissAllNotices(
                    paneId: command.key.paneId, includingDrawers: context.includingDrawers))
        }
        return await finishPerson(command, resolution: resolution, context: context)
    }

    private func cardRequestRefusal(_ context: PersonContext, command: PersonCommand)
        -> PaneContextPopoverPersonCompletion?
    {
        guard case .card = context.snapshot, command.intent.messageKey != nil else { return nil }
        return .init(id: command.id, resolution: .refused(.requestNotCurrent), presentation: .keepPopover)
    }

    func retiredPerson(_ command: PersonCommand) -> PaneContextPopoverPersonCompletion {
        .init(id: command.id, resolution: .refused(.openingRetired), presentation: .openingRetired)
    }

    func finishPerson(
        _ command: PersonCommand, resolution: PaneContextPopoverPersonCompletion.Resolution, context: PersonContext
    ) async -> PaneContextPopoverPersonCompletion {
        let feedback = await personFeedback(resolution, command: command, context: context)
        guard personIsCurrent(command), var consumer = consumers[command.key] else {
            return .init(id: command.id, resolution: resolution, presentation: .openingRetired)
        }
        if consumer.latestPersonCommand == command.id { consumer.actionFeedback = feedback }
        consumer.pendingPersonRefreshes.insert(command.id)
        consumers[command.key] = consumer
        refreshImmediately(command.key, opening: command.opening)
        var joinedProducer: UUID?
        while personIsCurrent(command), consumers[command.key]?.pendingPersonRefreshes.contains(command.id) == true {
            if let operation = consumers[command.key]?.inputOperation {
                // Input application may separate a superseded read from its immediate successor.
                await awaitInputCompletion(operation, key: command.key, opening: command.opening)
                continue
            }
            guard let producer = consumers[command.key]?.latestExecution, producer.id != joinedProducer else { break }
            // Each step joins a distinct real operation; no cadence or polling wait is introduced.
            joinedProducer = producer.id
            await producer.task.value
        }
        if personIsCurrent(command), var remaining = consumers[command.key] {
            remaining.pendingPersonRefreshes.remove(command.id)
            consumers[command.key] = remaining
        }
        let presentation: PaneContextPopoverPersonCompletion.Presentation
        if !personIsCurrent(command) {
            presentation = .openingRetired
        } else if case .action(.goToPane(.focused)) = resolution {
            presentation = .dismissPopover
        } else {
            presentation = .keepPopover
        }
        return .init(id: command.id, resolution: resolution, presentation: presentation)
    }

    func personFeedback(
        _ resolution: PaneContextPopoverPersonCompletion.Resolution, command: PersonCommand, context: PersonContext
    ) async -> String? {
        switch resolution {
        case .answer(let result): await PaneContextPopoverFeedback.answer(result, location: context.location)
        case .dismiss(let result):
            if let key = command.intent.messageKey {
                await PaneContextPopoverFeedback.dismiss(
                    result, messageId: key.messageId, source: key.paneId, snapshot: context.snapshot,
                    location: context.location)
            } else {
                nil
            }
        case .action(let result): await PaneContextPopoverFeedback.action(result)
        case .dismissAll(let result): await PaneContextPopoverFeedback.dismissAll(result)
        case .refused(.answerInMessages): "Answer this ask in Messages"
        case .refused(.dismissNotAvailable): "This message cannot be dismissed here"
        case .refused(.actionNotAvailable): "This message action is not available here"
        case .refused(.requestNotCurrent), .refused(.openingRetired): nil
        }
    }
}
