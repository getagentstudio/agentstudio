import AgentStudioPrimitives
import Darwin
import Foundation

/// Prepares one complete skill generation before provider configuration changes,
/// then publishes it with one directory rename. Readers never see mixed files.
struct PreparedAgentSkillDirectory {
    private let stagingRoot: URL
    private let candidate: URL
    private let fileManager: FileManager

    init(source: URL, providerHome: URL, marker: Data, fileManager: FileManager = .default) throws {
        let stagingRoot = providerHome.appending(path: ".agentstudio-skill-\(UUIDv7.generate().uuidString)")
        // Reserve ownership before cleanup can run; a collision is never ours.
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let candidate = stagingRoot.appending(path: "agentstudio")
        do {
            guard fileManager.isReadableFile(atPath: source.appending(path: "SKILL.md").path) else {
                throw AgentPackageInstallationError.packageResourcesUnavailable
            }
            try fileManager.copyItem(at: source, to: candidate)
            try marker.write(to: candidate.appending(path: ".agentstudio-package"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
        self.stagingRoot = stagingRoot
        self.candidate = candidate
        self.fileManager = fileManager
    }

    func publish(to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue { throw CocoaError(.fileWriteFileExists) }
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// After a swap the retired generation is inside our staging root. Cleanup
    /// failure cannot undo a committed publication or expose a partial tree.
    func discardStaging() {
        try? fileManager.removeItem(at: stagingRoot)
    }
}
