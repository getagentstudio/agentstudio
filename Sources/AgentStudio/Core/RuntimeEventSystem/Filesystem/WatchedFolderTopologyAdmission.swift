import AgentStudioInfrastructure
import CoreServices
import Foundation

/// Immutable discovery knowledge shared with callback intake; paths use the root's comparison form.
package struct WatchedFolderAdmissionSnapshot: Sendable, Equatable {
    package let canonicalRoot: String
    package let lexicalRoot: String
    package let casePolicy: FilesystemVolumeCasePolicy
    package let knownCheckoutPaths: Set<String>
    package let maxScanDepth: Int

    init(root: RegisteredRootDescriptor, knownGroups: [RepoScanner.RepoScanGroup], heldCheckoutPaths: [String] = []) {
        casePolicy = root.volumeSemantics.casePolicy
        canonicalRoot = Self.comparisonPath(root.aliases.onceResolvedCanonical.path, policy: casePolicy)
        lexicalRoot = Self.comparisonPath(root.aliases.standardizedLexical.path, policy: casePolicy)
        maxScanDepth = RepoScanner.defaultMaxDepth
        let canonicalRoot = canonicalRoot
        let lexicalRoot = lexicalRoot
        let policy = casePolicy
        knownCheckoutPaths = Set(
            (knownGroups.flatMap { [$0.clonePath.path] + $0.linkedWorktreePaths.map(\.path) } + heldCheckoutPaths).map {
                let path = Self.comparisonPath($0, policy: policy)
                return Self.contains(path, within: lexicalRoot)
                    ? canonicalRoot + path.dropFirst(lexicalRoot.count) : path
            })
    }

    func canonicalComparisonPath(_ rawPath: String) -> String {
        let path = Self.comparisonPath(rawPath, policy: casePolicy)
        return Self.contains(path, within: lexicalRoot)
            ? canonicalRoot + path.dropFirst(lexicalRoot.count) : path
    }

    static func comparisonPath(_ path: String, policy: FilesystemVolumeCasePolicy) -> String {
        let normalized = FilesystemRootOwnership.canonicalizeKernelPath(path).precomposedStringWithCanonicalMapping
        return policy == .caseInsensitive ? normalized.lowercased() : normalized
    }

    static func contains(_ path: String, within root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}

/// Interprets source facts without I/O; ordinary work inside a known checkout cannot change scan membership.
enum WatchedFolderTopologyAdmission {
    private static let routineGitFiles: Set<String> = [
        "index", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD",
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
        shouldScan(batch, snapshot: .init(root: root, knownGroups: knownGroups, heldCheckoutPaths: heldCheckoutPaths))
    }

    static func shouldScan(_ batch: FSEventBatch, snapshot: WatchedFolderAdmissionSnapshot) -> Bool {
        filterBatch(batch, snapshot: snapshot) != nil
    }

    static func filterBatch(_ batch: FSEventBatch, snapshot: WatchedFolderAdmissionSnapshot) -> FSEventBatch? {
        var observationFlagsByPath: [String: UInt32] = [:]
        for observation in batch.observations {
            observationFlagsByPath[snapshot.canonicalComparisonPath(observation.path), default: 0] |= observation.flags
        }
        func isRelevant(_ rawPath: String) -> Bool {
            let path = snapshot.canonicalComparisonPath(rawPath)
            let flags = observationFlagsByPath[path]
            if let flags, FSEventObservation(path: rawPath, eventID: 0, flags: flags).hasCoverageLoss { return true }
            if isGitTopologyPath(path) {
                guard let checkout = knownCheckout(containing: path, knownPaths: snapshot.knownCheckoutPaths) else {
                    return true
                }
                return admitsGitPath(
                    String(path.dropFirst(checkout == "/" ? 1 : checkout.count + 1)),
                    observationFlags: flags, casePolicy: snapshot.casePolicy)
            }
            guard let flags,
                isDirectoryStructureChange(.init(path: rawPath, eventID: 0, flags: flags)),
                WatchedFolderAdmissionSnapshot.contains(path, within: snapshot.canonicalRoot)
            else { return false }
            if let checkout = knownCheckout(containing: path, knownPaths: snapshot.knownCheckoutPaths), path != checkout
            {
                return false
            }
            // Existing checkouts and their ancestors stay discoverable even with a stale snapshot.
            if snapshot.knownCheckoutPaths.contains(where: { WatchedFolderAdmissionSnapshot.contains($0, within: path) }
            ) {
                return true
            }
            let components = path.dropFirst(snapshot.canonicalRoot == "/" ? 1 : snapshot.canonicalRoot.count + 1)
                .split(separator: "/")
            return components.count <= snapshot.maxScanDepth && !components.contains { $0.hasPrefix(".") }
        }
        let paths = batch.paths.filter(isRelevant)
        let observations = batch.observations.filter { isRelevant($0.path) }
        guard batch.requiresFullGitRefresh || !paths.isEmpty || !observations.isEmpty else { return nil }
        return FSEventBatch(
            worktreeId: batch.worktreeId, paths: paths, participant: batch.participant,
            observations: observations, requiresFullGitRefresh: batch.requiresFullGitRefresh)
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
        if gitPath == "objects" || gitPath == "refs" {
            // A rename can remove a required entry without carrying a removal flag.
            let invalidatingFlags = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            return observationFlags.map { $0 & invalidatingFlags != 0 } ?? true
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

}
