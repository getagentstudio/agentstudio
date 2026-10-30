import AgentStudioSharedComponents
import Foundation
import Observation
import SwiftUI

/// One opening's inputs and read target; compatibility is prepared off-main.
@MainActor
@Observable
final class PaneContextPopoverInteractionState {
    @MainActor @Observable
    fileprivate final class Entry {
        let version: UUID
        var draft = AskFormDraft()
        init(version: UUID) { self.version = version }
    }
    private enum DetailSelection {
        case message(version: UUID, value: PaneContextMessageTextValue)
        case providerPrompt(version: UUID, value: PaneContextMessageTextValue)
        var value: PaneContextMessageTextValue {
            switch self {
            case .message(_, let value), .providerPrompt(_, let value): value
            }
        }
    }
    private var opening: UInt64?
    private var entries: [MessageRowModel.Key: Entry] = [:]
    private var selectedDetails: DetailSelection?
    var selectedFilter = 0
    var retainedRowCount: Int {
        guard let selectedDetails else { return entries.count }
        if case .message(let key) = selectedDetails.value.key, entries[key] != nil { return entries.count }
        return entries.count + 1
    }

    func beginOpening(_ opening: UInt64, initialSelection: Int) {
        close()
        self.opening = opening
        selectedFilter = initialSelection
    }

    func close() {
        opening = nil
        entries.removeAll()
        selectedDetails = nil
        selectedFilter = 0
    }

    func apply(
        _ versions: [MessageRowModel.Key: UUID], providerVersions: [PaneContextTextBodyKey: UUID] = [:], opening: UInt64
    ) {
        guard self.opening == opening else { return }
        for (key, entry) in entries where versions[key] != entry.version { entries.removeValue(forKey: key) }
        if case .message(let version, let value)? = selectedDetails,
            case .message(let key) = value.key, versions[key] != version
        {
            selectedDetails = nil
        }
        if case .providerPrompt(let version, let value)? = selectedDetails,
            let current = providerVersions[value.key], current != version
        {
            selectedDetails = nil
        }
    }

    func clear(_ key: MessageRowModel.Key, version: UUID?, opening: UInt64) {
        guard self.opening == opening else { return }
        if entries[key]?.version == version { entries.removeValue(forKey: key) }
        if case .message(let selectedVersion, let value)? = selectedDetails,
            value.key == .message(key), selectedVersion == version
        {
            selectedDetails = nil
        }
    }

    func clear(_ versions: [MessageRowModel.Key: UUID], opening: UInt64) {
        guard self.opening == opening else { return }
        for (key, version) in versions { clear(key, version: version, opening: opening) }
    }

    private func entryForWrite(_ key: MessageRowModel.Key, version: UUID) -> Entry {
        if let entry = entries[key], entry.version == version { return entry }
        let entry = Entry(version: version)
        entries[key] = entry
        return entry
    }

    func bindings(
        versions: [MessageRowModel.Key: UUID], opening: UInt64,
        currentVersions: @escaping @MainActor () -> [MessageRowModel.Key: UUID]?,
        providerVersions: [PaneContextTextBodyKey: UUID] = [:],
        currentProviderVersions: @escaping @MainActor () -> [PaneContextTextBodyKey: UUID]? = { [:] }
    ) -> MessagesPopoverBindings {
        .init(
            selectedFilter: .init(
                get: { self.opening == opening ? self.selectedFilter : 0 },
                set: { if self.opening == opening { self.selectedFilter = $0 } }),
            draft: { key in
                let version = versions[key]
                return .init(
                    get: {
                        guard self.opening == opening, let version, currentVersions()?[key] == version,
                            self.entries[key]?.version == version
                        else { return .init() }
                        return self.entries[key]?.draft ?? .init()
                    },
                    set: { value in
                        guard self.opening == opening, let version, currentVersions()?[key] == version else { return }
                        let entry = self.entryForWrite(key, version: version)
                        if entry.draft != value { entry.draft = value }
                    })
            },
            details: .init(
                get: {
                    guard self.opening == opening else { return nil }
                    if case .message(let version, let value)? = self.selectedDetails,
                        case .message(let key) = value.key, currentVersions()?[key] != version
                    {
                        return nil
                    }
                    if case .providerPrompt(let version, let value)? = self.selectedDetails,
                        let current = currentProviderVersions()?[value.key], current != version
                    {
                        return nil
                    }
                    return self.selectedDetails?.value
                },
                set: { value in
                    guard self.opening == opening else { return }
                    guard let value else {
                        self.selectedDetails = nil
                        return
                    }
                    switch value.key {
                    case .message(let key):
                        guard let version = versions[key], currentVersions()?[key] == version else { return }
                        self.selectedDetails = .message(version: version, value: value)
                    case .providerPrompt:
                        guard let version = providerVersions[value.key],
                            currentProviderVersions()?[value.key] == version
                        else { return }
                        self.selectedDetails = .providerPrompt(version: version, value: value)
                    }
                }))
    }
}
