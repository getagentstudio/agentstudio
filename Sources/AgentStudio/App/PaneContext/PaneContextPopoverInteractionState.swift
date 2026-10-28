import AgentStudioSharedComponents
import Foundation
import Observation
import SwiftUI

/// One opening's input values. Compatibility is prepared off-main; this owner applies version fences and mutations.
@MainActor
@Observable
final class PaneContextPopoverInteractionState {
    @MainActor @Observable
    fileprivate final class Entry {
        let version: UUID
        var draft = AskFormDraft()
        var expanded = false
        init(version: UUID) { self.version = version }
    }
    private var opening: UInt64?
    private var entries: [MessageRowModel.Key: Entry] = [:]
    var selectedFilter = 0
    var retainedRowCount: Int { entries.count }

    func beginOpening(_ opening: UInt64) {
        close()
        self.opening = opening
    }

    func close() {
        opening = nil
        entries.removeAll()
        selectedFilter = 0
    }

    func apply(_ versions: [MessageRowModel.Key: UUID], opening: UInt64) {
        guard self.opening == opening else { return }
        for (key, entry) in entries where versions[key] != entry.version { entries.removeValue(forKey: key) }
    }

    func clear(_ key: MessageRowModel.Key, version: UUID?, opening: UInt64) {
        guard self.opening == opening, entries[key]?.version == version else { return }
        entries.removeValue(forKey: key)
    }

    func clear(_ versions: [MessageRowModel.Key: UUID], opening: UInt64) {
        guard self.opening == opening else { return }
        for (key, entry) in entries where versions[key] == entry.version { entries.removeValue(forKey: key) }
    }

    private func entryForWrite(_ key: MessageRowModel.Key, version: UUID) -> Entry {
        if let entry = entries[key], entry.version == version { return entry }
        let entry = Entry(version: version)
        entries[key] = entry
        return entry
    }

    func bindings(
        versions: [MessageRowModel.Key: UUID], opening: UInt64,
        currentVersions: @escaping @MainActor () -> [MessageRowModel.Key: UUID]?
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
            expanded: { key in
                let version = versions[key]
                return .init(
                    get: {
                        guard self.opening == opening, let version, currentVersions()?[key] == version,
                            self.entries[key]?.version == version
                        else { return false }
                        return self.entries[key]?.expanded ?? false
                    },
                    set: { value in
                        guard self.opening == opening, let version, currentVersions()?[key] == version else { return }
                        let entry = self.entryForWrite(key, version: version)
                        if entry.expanded != value { entry.expanded = value }
                    })
            })
    }
}
