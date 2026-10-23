import Foundation

package enum ProviderHookOwnership: Equatable, Sendable {
    case current, legacy, foreign

    package static func classify(_ handler: ProviderHookHandler, layout: ProviderIntegrationLayout) -> Self {
        guard case .command(let hook) = handler else { return .foreign }
        if hook.command.contains(ProviderExpectedEntries.shellQuotedPath(layout.scriptURL.path)) { return .current }
        let legacy =
            "/AgentPackage/providers/\(layout.provider.rawValue)/hooks/agentstudio-\(layout.provider.rawValue)-hook.sh"
        return hook.command.contains(legacy) ? .legacy : .foreign
    }
}

package struct ProviderHookIndexMove: Equatable, Sendable {
    package let event: String
    package let oldGroup: Int
    package let oldHandler: Int
    package let newGroup: Int
    package let newHandler: Int
}

package struct ProviderHookMergeResult: Equatable, Sendable {
    package let document: ProviderHookFileDocument
    package let shiftedForeignKeys: [ProviderHookIndexMove]
    package let replacedEvents: [String]
}

package enum ProviderHookMerge {
    package static func applying(
        to original: ProviderHookFileDocument, layout: ProviderIntegrationLayout, removing: Bool = false
    ) -> ProviderHookMergeResult {
        var document = original
        var shifted: [ProviderHookIndexMove] = []
        var replaced: [String] = []
        let expected = removing ? [] : ProviderExpectedEntries.entries(layout: layout)
        let eventNames = original.eventOrder + expected.map(\.event).filter { !original.eventOrder.contains($0) }
        for event in eventNames {
            let groups = original.groupsByEvent[event] ?? []
            let desired = expected.first(where: { $0.event == event })?.group
            let keeper = groups.enumerated().compactMap { groupIndex, group -> (Int, Int)? in
                guard let desired, group.matcher == desired.matcher,
                    let handlerIndex = group.handlers.firstIndex(where: {
                        ProviderHookOwnership.classify($0, layout: layout) != .foreign
                    })
                else { return nil }
                return (groupIndex, handlerIndex)
            }.first
            var result: [ProviderHookGroup] = []
            var foundOwned = false
            for (groupIndex, originalGroup) in groups.enumerated() {
                var group = originalGroup
                group.handlers = []
                for (handlerIndex, handler) in originalGroup.handlers.enumerated() {
                    if ProviderHookOwnership.classify(handler, layout: layout) == .foreign {
                        let newGroup = result.count
                        let newHandler = group.handlers.count
                        if newGroup != groupIndex || newHandler != handlerIndex {
                            shifted.append(
                                .init(
                                    event: event, oldGroup: groupIndex, oldHandler: handlerIndex, newGroup: newGroup,
                                    newHandler: newHandler))
                        }
                        group.handlers.append(handler)
                    } else {
                        foundOwned = true
                        if let keeper, keeper.0 == groupIndex, keeper.1 == handlerIndex, let desired {
                            for replacement in desired.handlers {
                                group.handlers.append(
                                    handler.json.semanticallyEquals(replacement.json) ? handler : replacement)
                            }
                        }
                    }
                }
                if !group.handlers.isEmpty || originalGroup.handlers.isEmpty { result.append(group) }
            }
            if let desired, keeper == nil { result.append(desired) }
            if foundOwned,
                !ProviderHookJSONValue.array(result.map(\.json)).semanticallyEquals(.array(groups.map(\.json)))
            {
                replaced.append(event)
            }
            document.setGroups(result, event: event)
        }
        return .init(document: document, shiftedForeignKeys: shifted, replacedEvents: replaced)
    }

    package static func report(_ result: ProviderHookMergeResult, layout: ProviderIntegrationLayout) -> [String] {
        var lines = result.replacedEvents.map { "notice: replacing modified agentstudio entry \($0)" }
        if layout.provider == .codex {
            lines += result.shiftedForeignKeys.map {
                "Codex will ask you to review again: \($0.event) group \($0.oldGroup) handler \($0.oldHandler) (\(layout.hookFileURL.path)); moved to group \($0.newGroup) handler \($0.newHandler)"
            }
        }
        return lines
    }
}
