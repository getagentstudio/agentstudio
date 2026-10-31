import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

/// Non-authoritative compatibility observations retained only for this family's opening.
struct PaneContextPopoverInteractionIndex: Sendable {
    struct Signature: Sendable, Equatable {
        enum Content: Sendable, Equatable {
            case notice(NoticeState)
            case ask(AskReason, AskForm, live: Bool)
        }
        let sender: AgentMessageSender
        let body: String
        let explanation: String?
        let content: Content
    }
    struct Entry: Sendable, Equatable {
        let signature: Signature
        let version: UUID
    }
    struct ProviderEntry: Sendable, Equatable {
        let bindingGeneration: UUID
        let prompt: SessionProviderPromptSummary
        let version: UUID
    }
    let entries: [MessageRowModel.Key: Entry]
    let versions: [MessageRowModel.Key: UUID]
    let noticeVersions: [MessageRowModel.Key: UUID]
    let providerEntries: [PaneContextTextBodyKey: ProviderEntry]
    let providerVersions: [PaneContextTextBodyKey: UUID]
    static let empty = Self(
        entries: [:], versions: [:], noticeVersions: [:], providerEntries: [:], providerVersions: [:])

    nonisolated static func prepare(
        _ snapshot: PaneContextPopoverSnapshot, baseline: Self,
        detail: PaneContextDetail?, selection: PaneContextPopoverSelectedAsk
    ) -> Self {
        if case .paneGone = snapshot.state { return .empty }
        var entries = baseline.entries
        let owner = snapshot.identity.key.paneId
        let scope: Set<UUID>?
        if let facts = snapshot.capture.sources[owner]?.structuralFacts {
            scope = Set(
                [owner.uuid]
                    + (snapshot.demand.includingDrawers && !facts.isDrawerChild ? facts.ownedDrawerPaneIDs : []))
        } else {
            scope = nil
        }
        if let scope { entries = entries.filter { scope.contains($0.key.sourcePaneId) } }
        var providerEntries = baseline.providerEntries
        if let scope {
            providerEntries = providerEntries.filter {
                guard case .providerPrompt(let source, _) = $0.key else { return false }
                return scope.contains(source)
            }
        }
        for source in detail?.scopedSessions ?? [] {
            guard scope?.contains(source.sourcePaneId.uuid) != false, let session = source.session else { continue }
            // A known rebind retires old read versions even when its prompt page is empty.
            for (key, entry) in providerEntries {
                guard case .providerPrompt(let pane, _) = key, pane == source.sourcePaneId.uuid,
                    entry.bindingGeneration != session.bindingGeneration
                else { continue }
                providerEntries[key] = .init(
                    bindingGeneration: session.bindingGeneration, prompt: entry.prompt, version: UUIDv7.generate())
            }
            for (ordinal, prompt) in session.providerPrompts.enumerated() {
                let key = PaneContextTextBodyKey.providerPrompt(source: source.sourcePaneId.uuid, ordinal: ordinal)
                if providerEntries[key]?.bindingGeneration != session.bindingGeneration
                    || providerEntries[key]?.prompt != prompt
                {
                    providerEntries[key] = .init(
                        bindingGeneration: session.bindingGeneration, prompt: prompt, version: UUIDv7.generate())
                }
            }
        }
        var observed = detail.map { $0.messages + $0.drawerMessages.flatMap(\.messages) } ?? []
        var explicitlyRetired = Set<MessageRowModel.Key>()
        switch selection {
        case .current(let selected): observed.append(selected.detail)
        case .pendingRefresh(let key, let retained):
            if let retained, retained.key == key { observed.append(retained.detail) }
        case .notFound(let key), .settled(let key), .detached(let key):
            explicitlyRetired.insert(.init(sourcePaneId: key.paneId.uuid, messageId: key.messageId.uuid))
        case .none, .unavailable: break
        }
        for message in observed {
            let key = MessageRowModel.Key(sourcePaneId: message.sourcePaneId.uuid, messageId: message.id.uuid)
            guard scope?.contains(key.sourcePaneId) != false, !explicitlyRetired.contains(key) else { continue }
            guard PaneContextPresentationRules.messageGroup(for: message) != nil else {
                entries.removeValue(forKey: key)
                continue
            }
            let content: Signature.Content
            switch message.shape {
            case .notice(let state): content = .notice(state)
            case .ask(let reason, let form, _, let state): content = .ask(reason, form, live: state == .open)
            }
            let signature = Signature(
                sender: message.sender, body: message.body, explanation: message.why, content: content)
            if entries[key]?.signature != signature {
                entries[key] = .init(signature: signature, version: UUIDv7.generate())
            }
        }
        for key in explicitlyRetired { entries.removeValue(forKey: key) }
        // Missing keys are unknown: even nil truncation does not make settled-row coverage exhaustive.
        if entries == baseline.entries, providerEntries == baseline.providerEntries { return baseline }
        return .init(
            entries: entries, versions: entries.mapValues(\.version),
            noticeVersions: entries.compactMapValues { entry in
                if case .notice = entry.signature.content { entry.version } else { nil }
            }, providerEntries: providerEntries, providerVersions: providerEntries.mapValues(\.version))
    }
}
