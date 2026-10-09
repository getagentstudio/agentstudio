import AgentStudioInfrastructure
import CoreServices
import Foundation

/// Interprets source facts without I/O; ordinary work inside a known checkout cannot change scan membership.
enum WatchedFolderTopologyAdmission {
    private static let routineGitFiles: Set<String> = [
        "index", "HEAD", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD",
        "REVERT_HEAD", "REBASE_HEAD", "AUTO_MERGE", "BISECT_LOG", "COMMIT_EDITMSG", "packed-refs",
    ]
    private static let foldedRoutineGitFiles = Set(routineGitFiles.map { $0.lowercased() })
    private static let routineGitDirectories = [
        "objects", "refs", "logs", "modules", "rebase-merge", "rebase-apply", "sequencer",
    ]
    /// `heldCheckoutPaths` are destinations a creation owner is still materializing; their
    /// directory churn is ordinary work inside a checkout, not a membership change.
    static func shouldScan(
        _ batch: FSEventBatch, root: RegisteredRootDescriptor, knownGroups: [RepoScanner.RepoScanGroup],
        heldCheckoutPaths: [String] = []
    ) -> Bool {
        if batch.requiresFullGitRefresh || batch.observations.contains(where: \.hasCoverageLoss) {
            return true
        }
        let canonicalRoot = comparisonPath(
            root.aliases.onceResolvedCanonical.path, policy: root.volumeSemantics.casePolicy)
        let lexicalRoot = comparisonPath(root.aliases.standardizedLexical.path, policy: root.volumeSemantics.casePolicy)
        func canonicalComparisonPath(_ rawPath: String) -> String {
            let path = comparisonPath(rawPath, policy: root.volumeSemantics.casePolicy)
            return contains(path, within: lexicalRoot)
                ? canonicalRoot + path.dropFirst(lexicalRoot.count) : path
        }
        let knownPaths =
            (knownGroups.flatMap { [$0.clonePath] + $0.linkedWorktreePaths }.map(\.path)
            + heldCheckoutPaths)
            .map(canonicalComparisonPath)
        let knownPathSet = Set(knownPaths)
        var observationFlagsByPath: [String: UInt32] = [:]
        for observation in batch.observations {
            observationFlagsByPath[canonicalComparisonPath(observation.path), default: 0] |= observation.flags
        }
        if batch.paths.contains(where: { rawPath in
            let path = canonicalComparisonPath(rawPath)
            guard isGitTopologyPath(path) else { return false }
            guard let checkout = knownCheckout(containing: path, knownPaths: knownPathSet) else { return true }
            return admitsGitPath(
                String(path.dropFirst(checkout.count + 1)),
                observationFlags: observationFlagsByPath[path], casePolicy: root.volumeSemantics.casePolicy)
        }) {
            return true
        }
        guard batch.observations.contains(where: isDirectoryStructureChange) else { return false }
        return batch.observations.contains { observation in
            guard isDirectoryStructureChange(observation) else { return false }
            let path = canonicalComparisonPath(observation.path)
            guard contains(path, within: canonicalRoot) else { return false }
            return !knownPaths.contains { path != $0 && contains(path, within: $0) }
        }
    }

    private static func knownCheckout(containing path: String, knownPaths: Set<String>) -> String? {
        var candidate = path
        while true {
            if knownPaths.contains(candidate) { return candidate }
            guard candidate != "/", let separator = candidate.lastIndex(of: "/") else { return nil }
            candidate = separator == candidate.startIndex ? "/" : String(candidate[..<separator])
        }
    }

    private static func admitsGitPath(
        _ relativePath: String, observationFlags: UInt32?, casePolicy: FilesystemVolumeCasePolicy
    ) -> Bool {
        let components = relativePath.split(separator: "/")
        guard components.first == ".git", !components.dropFirst().contains(".git") else { return false }
        var gitComponents = components.dropFirst()
        if gitComponents.first == "worktrees", gitComponents.count >= 3 {
            gitComponents = gitComponents.dropFirst(2)
        }
        let gitPath = gitComponents.joined(separator: "/")
        let headPath = casePolicy == .caseInsensitive ? "head" : "HEAD"
        if gitPath == headPath || gitPath == "objects" || gitPath == "refs" {
            // Content writes are routine; lost entry validity or missing source flags are not.
            return observationFlags.map { $0 & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 } ?? true
        }
        let fileNames = casePolicy == .caseInsensitive ? foldedRoutineGitFiles : routineGitFiles
        if fileNames.contains(gitPath) || gitPath.hasSuffix(".lock") { return false }
        return !routineGitDirectories.contains { gitPath.hasPrefix($0 + "/") }
    }

    /// Overflow can lose precise observations, so retain whether the lost batch could require membership recovery.
    static func mayAffectTopology(_ batch: FSEventBatch) -> Bool {
        batch.requiresFullGitRefresh || batch.paths.contains(where: isGitTopologyPath)
            || batch.observations.contains { $0.hasCoverageLoss || isDirectoryStructureChange($0) }
    }

    private static func isDirectoryStructureChange(_ observation: FSEventObservation) -> Bool {
        let directoryFlag = UInt32(kFSEventStreamEventFlagItemIsDir)
        let structureFlags = UInt32(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
        )
        return observation.flags & directoryFlag != 0 && observation.flags & structureFlags != 0
    }

    private static func isGitTopologyPath(_ path: String) -> Bool {
        path.contains("/.git/") || path.hasSuffix("/.git")
    }

    private static func comparisonPath(_ path: String, policy: FilesystemVolumeCasePolicy) -> String {
        let normalized = FilesystemRootOwnership.canonicalizeKernelPath(path).precomposedStringWithCanonicalMapping
        return policy == .caseInsensitive ? normalized.lowercased() : normalized
    }

    private static func contains(_ path: String, within root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}
