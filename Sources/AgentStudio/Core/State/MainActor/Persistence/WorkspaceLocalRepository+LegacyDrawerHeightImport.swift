import AgentStudioInfrastructure
import Foundation
import GRDB

/// Inputs captured before the one-time cutover from the retired global drawer
/// height to per-owner preferences.
package struct LegacyDrawerPresentationImport: Equatable, Sendable {
    /// Finite legacy ratio, already clamped into the saved range.
    let normalHeightRatio: Double
    /// Owning layout panes of every persisted workspace that were created
    /// before the import cutoff.
    let owningPaneIdsByWorkspaceId: [UUID: Set<UUID>]

    package init?(legacyHeightRatio: Double?, owningPaneIdsByWorkspaceId: [UUID: Set<UUID>]) {
        guard let legacyHeightRatio,
            let normalHeightRatio = DrawerPresentationPreference.validatedNormalHeightRatio(legacyHeightRatio)
        else { return nil }
        self.normalHeightRatio = normalHeightRatio
        self.owningPaneIdsByWorkspaceId = owningPaneIdsByWorkspaceId
    }
}

/// Outcome of capturing the legacy import inputs at boot.
package enum LegacyDrawerPresentationImportCapture: Equatable, Sendable {
    /// No finite legacy height exists; nothing to import or clear.
    case noLegacyValue
    case captured(LegacyDrawerPresentationImport)
    /// Owning panes could not be read. Nothing is written and the legacy key
    /// stays as the pending marker for the next boot.
    case ownerEnumerationFailed
    /// Programming error: a legacy height is pending but boot did not establish
    /// the cutoff first. Capture never records one itself, so nothing is
    /// written and the legacy key stays pending.
    case importCutoffNotEstablished

    /// Captures the owners created before `importCutoff`, the cutoff the boot
    /// established with `establishPendingImportCutoff(now:)`. Capture only
    /// reads the cutoff; that boot step is its one writer.
    package static func capture(
        source: LegacyDrawerPresentationSource?,
        importCutoff: Date?,
        enumerateOwners: () throws -> [UUID: Set<UUID>]
    ) -> Self {
        guard let source, let legacyHeightRatio = source.readHeightRatio(),
            DrawerPresentationPreference.validatedNormalHeightRatio(legacyHeightRatio) != nil
        else { return .noLegacyValue }
        guard let importCutoff else { return .importCutoffNotEstablished }
        guard let owningPaneIdsByWorkspaceId = try? enumerateOwners() else { return .ownerEnumerationFailed }
        guard
            let legacyImport = LegacyDrawerPresentationImport(
                legacyHeightRatio: legacyHeightRatio,
                owningPaneIdsByWorkspaceId: owningPaneIdsByWorkspaceId.mapValues { owningPaneIds in
                    owningPaneIds.filter { ownerWasCreated($0, before: importCutoff) }
                }
            )
        else { return .noLegacyValue }
        return .captured(legacyImport)
    }

    /// Pane ids are UUIDv7, so an owner's creation time is its id's timestamp.
    /// An id that is not v7 predates this build and is always eligible.
    private static func ownerWasCreated(_ ownerPaneId: UUID, before importCutoff: Date) -> Bool {
        guard UUIDv7.isV7(ownerPaneId), let createdAt = UUIDv7.timestamp(from: ownerPaneId) else { return true }
        return createdAt < importCutoff
    }

    package var importToApply: LegacyDrawerPresentationImport? {
        guard case .captured(let legacyImport) = self else { return nil }
        return legacyImport
    }
}

/// Where the retired global drawer height is read from and cleared after the
/// import commits. Its presence is the import's pending marker. The import
/// cutoff is stored next to it in the same defaults domain, and both are
/// removed together. Production uses the app's scoped defaults; tests inject
/// their own values so they never touch a developer's defaults domain.
package struct LegacyDrawerPresentationSource: Sendable {
    package static let legacyHeightRatioKey = "drawerHeightRatio"
    package static let importCutoffKey = "drawerHeightRatioImportCutoff"

    let readHeightRatio: @Sendable () -> Double?
    let readImportCutoff: @Sendable () -> Date?
    let writeImportCutoff: @Sendable (Date) -> Void
    /// Removes the legacy height and the import cutoff together.
    let clear: @Sendable () -> Void

    package init(
        readHeightRatio: @escaping @Sendable () -> Double?,
        readImportCutoff: @escaping @Sendable () -> Date?,
        writeImportCutoff: @escaping @Sendable (Date) -> Void,
        clear: @escaping @Sendable () -> Void
    ) {
        self.readHeightRatio = readHeightRatio
        self.readImportCutoff = readImportCutoff
        self.writeImportCutoff = writeImportCutoff
        self.clear = clear
    }

    /// Returns the import cutoff while a finite legacy height is pending, and
    /// nil otherwise. The first boot that finds the pending key records `now`;
    /// a retry reuses that value, so owners created after the upgrade are never
    /// imported. Boot calls this before any local recovery branch can return,
    /// so a boot that leaves local storage unavailable still fixes the cutoff
    /// before panes can be created. The cutoff is truncated to whole
    /// milliseconds, the resolution of a UUIDv7 timestamp, so a pane minted in
    /// the cutoff's own millisecond is not counted as older than the cutoff.
    package func establishPendingImportCutoff(now: Date) -> Date? {
        guard let legacyHeightRatio = readHeightRatio(),
            DrawerPresentationPreference.validatedNormalHeightRatio(legacyHeightRatio) != nil
        else { return nil }
        if let recordedCutoff = readImportCutoff() { return recordedCutoff }
        let millisecondCutoff = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000
        )
        writeImportCutoff(millisecondCutoff)
        return millisecondCutoff
    }

    package static let appUserDefaults = Self(
        readHeightRatio: {
            AppStorageIdentity.current.userDefaults.object(forKey: legacyHeightRatioKey) as? Double
        },
        readImportCutoff: {
            AppStorageIdentity.current.userDefaults.object(forKey: importCutoffKey) as? Date
        },
        writeImportCutoff: { importCutoff in
            AppStorageIdentity.current.userDefaults.set(importCutoff, forKey: importCutoffKey)
        },
        clear: {
            AppStorageIdentity.current.userDefaults.removeObject(forKey: legacyHeightRatioKey)
            AppStorageIdentity.current.userDefaults.removeObject(forKey: importCutoffKey)
        }
    )
}

extension WorkspaceLocalRepository {
    /// Writes the legacy height for every captured owning pane in one local
    /// transaction. Rows an ordinary save already wrote are kept.
    func importLegacyDrawerHeight(_ legacyImport: LegacyDrawerPresentationImport) throws {
        let importedAt = Date().timeIntervalSince1970
        try databaseWriter.write { database in
            for (workspaceId, owningPaneIds) in legacyImport.owningPaneIdsByWorkspaceId {
                for ownerPaneId in owningPaneIds {
                    try database.execute(
                        sql: """
                            INSERT OR IGNORE INTO local_drawer_presentation(
                                workspace_id, owner_pane_id, normal_height_ratio, zoom_side, updated_at
                            )
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            workspaceId.uuidString,
                            ownerPaneId.uuidString,
                            legacyImport.normalHeightRatio,
                            DrawerZoomSide.terminal.rawValue,
                            importedAt,
                        ]
                    )
                }
            }
        }
    }
}
