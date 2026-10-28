import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

extension PaneContextPopoverRefreshOwner {
    struct ReadContext {
        let key: PaneContextPopoverConsumerKey
        let service: PaneContextPopoverServicePorts
        let versions: [PaneId: UInt64]
        let id: UUID
        let opening: UInt64
        let generation: UInt64
    }

    struct Assembly {
        let state: PaneContextPopoverSnapshot.State
        let pages: Set<PaneContextPopoverPageScope>
    }

    func assemble(_ context: ReadContext) async -> Assembly? {
        let key = context.key
        let service = context.service
        let versions = context.versions
        let opening = context.opening
        let generation = context.generation
        let id = context.id
        guard let consumer = consumers[key] else { return nil }
        let needsDetail = requiresDetail(consumer.demand.content, for: key)
        if !needsDetail {
            guard
                await validateVersions(
                    versions, key: key, service: service, opening: opening, generation: generation)
            else { return nil }
            return .init(state: .ready(.compact), pages: [])
        }
        guard
            let first = await readDetail(
                .first, context: context
            )
        else { return nil }
        var detail: PaneContextDetail
        switch first {
        case .detail(let value): detail = value
        case .paneGone: return .init(state: .paneGone, pages: [])
        case .unavailable(let failure):
            observe(.execution(key, id), .readFailed(failure))
            return .init(state: .unavailable(failure, retained: consumer.retained), pages: consumer.loadedPages)
        case .sourceNotInView:
            let failure = StorageFailureSummary.decodeFailed("sourceNotInView")
            observe(.execution(key, id), .readFailed(failure))
            return .init(state: .unavailable(failure, retained: consumer.retained), pages: consumer.loadedPages)
        }
        var scopes = consumer.loadedPages.union(consumer.pendingPages.keys)
        if case .detail(let previous, _) = consumer.retained, previous.revision != detail.revision {
            refusePages(key, scopes: scopes, outcome: .restartedOnRevision)
            scopes.removeAll()
        }
        let sourceOrder = Dictionary(
            uniqueKeysWithValues: orderedSources(key).enumerated().map { ($0.element, $0.offset) })
        let ordered = scopes.sorted { pageOrder($0, $1, sourceOrder: sourceOrder) }
        var loaded: Set<PaneContextPopoverPageScope> = []
        for scope in ordered {
            guard
                let page = await readDetail(
                    scope.readPage, context: context)
            else { return nil }
            switch page {
            case .detail(let next):
                let merged = await PaneContextPopoverPaging.merge(previous: detail, next: next, page: scope.readPage)
                guard
                    await validateVersions(
                        versions, key: key, service: service, opening: opening, generation: generation)
                else { return nil }
                switch merged {
                case .detail(let value):
                    detail = value
                    loaded.insert(scope)
                case .restartFirst:
                    refusePages(key, scopes: scopes, outcome: .restartedOnRevision)
                    guard
                        let restarted = await readDetail(
                            .first, context: context)
                    else { return nil }
                    switch restarted {
                    case .detail(let value): detail = value
                    case .paneGone: return .init(state: .paneGone, pages: [])
                    case .unavailable(let failure):
                        return .init(state: .unavailable(failure, retained: consumer.retained), pages: [])
                    case .sourceNotInView:
                        return .init(
                            state: .unavailable(.decodeFailed("sourceNotInView"), retained: consumer.retained),
                            pages: [])
                    }
                    return await finishDetail(
                        detail, pages: [], context: context)
                }
            case .sourceNotInView:
                refusePages(key, scopes: [scope], outcome: .sourceRemoved)
            case .paneGone: return .init(state: .paneGone, pages: [])
            case .unavailable(let failure):
                observe(.execution(key, id), .readFailed(failure))
                return .init(state: .unavailable(failure, retained: consumer.retained), pages: consumer.loadedPages)
            }
        }
        return await finishDetail(
            detail, pages: loaded, context: context)
    }

    func readDetail(_ page: PaneContextReadPage, context: ReadContext) async -> PaneContextReadResult? {
        let key = context.key
        let service = context.service
        let versions = context.versions
        let opening = context.opening
        let generation = context.generation
        let id = context.id
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return nil }
        observe(.execution(key, id), .readStarted(.detail(page)))
        let result = await service.reader.readDetail(.init(paneId: key.paneId, page: page))
        observe(.execution(key, id), .readCompleted(.detail(page)))
        guard await validateVersions(versions, key: key, service: service, opening: opening, generation: generation)
        else { return nil }
        return result
    }

    func finishDetail(
        _ detail: PaneContextDetail, pages: Set<PaneContextPopoverPageScope>, context: ReadContext
    ) async -> Assembly? {
        let key = context.key
        let service = context.service
        let versions = context.versions
        let opening = context.opening
        let generation = context.generation
        let id = context.id
        guard let consumer = consumers[key],
            isCurrent(key, opening: opening, epoch: service.epoch, generation: generation)
        else { return nil }
        switch consumer.demand.content {
        case .messages(.message(let focused)):
            guard detail.scopedSessions.contains(where: { $0.sourcePaneId == focused.paneId }) else {
                return .init(state: .ready(.detail(detail, selectedAsk: .none)), pages: pages)
            }
            guard
                let exact = await readMessage(
                    focused, context: context)
            else { return nil }
            switch exact {
            case .found(let message) where message.sourcePaneId == focused.paneId && message.id == focused.messageId:
                let supplemented = await PaneContextFocusedMessageProjection.including(message, in: detail)
                guard
                    await validateVersions(
                        versions, key: key, service: service, opening: opening, generation: generation)
                else { return nil }
                return .init(state: .ready(.detail(supplemented, selectedAsk: .none)), pages: pages)
            case .found, .notFound: break
            case .unavailable(let failure):
                observe(.execution(key, id), .readFailed(failure))
                return .init(state: .unavailable(failure, retained: consumer.retained), pages: consumer.loadedPages)
            }
        case .card:
            if case .ask(let source, let message) = cardSelection(key) {
                let selectedKey = PaneContextMessageKey(paneId: source, messageId: message)
                guard consumer.sources.contains(source),
                    detail.scopedSessions.contains(where: { $0.sourcePaneId == source })
                else { return .init(state: .ready(.detail(detail, selectedAsk: .detached(selectedKey))), pages: pages) }
                guard
                    let result = await readMessage(
                        selectedKey, context: context)
                else { return nil }
                let selection: PaneContextPopoverSelectedAsk
                switch result {
                case .found(let found) where found.id == message && found.sourcePaneId == source:
                    if case .ask(_, _, _, .open) = found.shape {
                        selection = .current(.init(key: selectedKey, detail: found, generation: generation))
                    } else {
                        selection = .settled(selectedKey)
                    }
                case .found, .notFound: selection = .notFound(selectedKey)
                case .unavailable(let failure): selection = .unavailable(selectedKey, failure)
                }
                return .init(state: .ready(.detail(detail, selectedAsk: selection)), pages: pages)
            }
        case .messages, .agentLine, .toolbar: break
        }
        return .init(state: .ready(.detail(detail, selectedAsk: .none)), pages: pages)
    }

    func readMessage(_ message: PaneContextMessageKey, context: ReadContext) async -> MessageReadResult? {
        let key = context.key
        let service = context.service
        let versions = context.versions
        let opening = context.opening
        let generation = context.generation
        let id = context.id
        guard isCurrent(key, opening: opening, epoch: service.epoch, generation: generation) else { return nil }
        observe(.execution(key, id), .readStarted(.message(message)))
        let result = await service.reader.readMessage(source: message.paneId, message: message.messageId)
        observe(.execution(key, id), .readCompleted(.message(message)))
        guard await validateVersions(versions, key: key, service: service, opening: opening, generation: generation)
        else { return nil }
        return result
    }

    func requiresDetail(_ content: PaneContextPopoverDemand.Content, for key: PaneContextPopoverConsumerKey) -> Bool {
        switch content {
        case .toolbar: false
        case .card: cardNeedsDetail(key)
        case .messages, .agentLine: true
        }
    }

    func canonicalSources(
        _ capture: PopoverSourceCapture, key: PaneContextPopoverConsumerKey,
        demand: PaneContextPopoverDemand
    ) -> [PaneId] {
        let owner = capture.sources[key.paneId]?.structuralFacts
        if demand.includingDrawers, owner?.isDrawerChild != true {
            return [key.paneId] + (owner?.ownedDrawerPaneIDs ?? []).map { PaneId(existingUUID: $0) }
        }
        return [key.paneId]
    }

    func cardSelection(_ key: PaneContextPopoverConsumerKey) -> CardRequestSelection {
        guard let consumer = consumers[key], let capture = consumer.capture else { return .none }
        return cardSelection(capture, key: key, demand: consumer.demand)
    }

    func cardSelection(
        _ capture: PopoverSourceCapture, key: PaneContextPopoverConsumerKey,
        demand: PaneContextPopoverDemand
    ) -> CardRequestSelection {
        let owner = capture.sources[key.paneId]
        let counts =
            owner?.structuralFacts?.isDrawerChild == true ? owner?.display?.own : owner?.display?.includingDrawers
        if let selected = counts?.oldestOpenAsk { return .ask(source: selected.paneId, message: selected.messageId) }
        let presentations = canonicalSources(capture, key: key, demand: demand).map {
            ($0, capture.sources[$0]?.session)
        }
        if let prompt = PaneContextPresentationRules.scopedCompactPrompt(presentations) {
            return .providerPrompt(source: prompt.source, prompt.prompt)
        }
        return .none
    }

    func cardNeedsDetail(_ key: PaneContextPopoverConsumerKey) -> Bool {
        guard let owner = consumers[key]?.capture?.sources[key.paneId] else { return false }
        let counts = owner.structuralFacts?.isDrawerChild == true ? owner.display?.own : owner.display?.includingDrawers
        return (counts?.kinds.needsYou ?? 0) + (counts?.kinds.failure ?? 0) > 0 || cardSelection(key) != .none
    }

    func refusePages(
        _ key: PaneContextPopoverConsumerKey, scopes: Set<PaneContextPopoverPageScope>,
        outcome: PaneContextPopoverOwnerFact.PageFinish
    ) {
        guard var consumer = consumers[key] else { return }
        consumer.loadedPages.subtract(scopes)
        for scope in scopes {
            for request in consumer.pendingPages.removeValue(forKey: scope) ?? [] {
                finishPage(request, outcome: outcome)
            }
        }
        consumers[key] = consumer
    }

    func orderedSources(_ key: PaneContextPopoverConsumerKey) -> [PaneId] {
        guard let consumer = consumers[key] else { return [] }
        let children = consumer.capture?.sources[key.paneId]?.structuralFacts?.ownedDrawerPaneIDs ?? []
        return ([key.paneId] + children.map { PaneId(existingUUID: $0) }).filter { consumer.sources.contains($0) }
    }

    func pageOrder(
        _ first: PaneContextPopoverPageScope, _ second: PaneContextPopoverPageScope,
        sourceOrder: [PaneId: Int]
    ) -> Bool {
        switch (first, second) {
        case (.messages(let left, let rankA, let positionA), .messages(let right, let rankB, let positionB)):
            if left != right { return (sourceOrder[left] ?? Int.max) < (sourceOrder[right] ?? Int.max) }
            return rankA == rankB ? positionA > positionB : rankA < rankB
        case (.messages, .sources): return true
        case (.sources, .messages): return false
        case (.sources(let left), .sources(let right)):
            return (sourceOrder[left] ?? Int.max) < (sourceOrder[right] ?? Int.max)
        }
    }
}
