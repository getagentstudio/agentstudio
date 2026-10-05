import AgentStudioGit
import Foundation

package enum WorktreeRemovalTarget: Sendable, Equatable {
    case worktree(GitWorktreeSnapshot, inputs: [String])
    case branch(name: String, inputs: [String])
    case alreadyRemoved(target: String, inputs: [String])
    case notFound(target: String, inputs: [String])

    package var targetName: String {
        switch self {
        case .worktree(let snapshot, _):
            snapshot.canonicalPath.standardizedFileURL.path
        case .branch(let name, _):
            name
        case .alreadyRemoved(let target, _), .notFound(let target, _):
            target
        }
    }

    package var inputs: [String] {
        switch self {
        case .worktree(_, let inputs), .branch(_, let inputs),
            .alreadyRemoved(_, let inputs), .notFound(_, let inputs):
            inputs
        }
    }
}

package struct WorktreeRemovalTargetResolver: Sendable {
    private enum Identity: Hashable {
        case worktree(GitWorktreeID)
        case branch(String)
        case alreadyRemoved(String)
        case notFound(String)
    }

    private struct ResolvedInput {
        let identity: Identity
        let target: WorktreeRemovalTarget
    }

    package init() {}

    package func resolve(
        _ targets: [String],
        callerDirectory: URL?,
        repositoryPath: URL,
        worktrees: [GitWorktreeSnapshot],
        branches: [GitBranchSnapshot]
    ) -> [WorktreeRemovalTarget] {
        var orderedIdentities: [Identity] = []
        var resultsByIdentity: [Identity: WorktreeRemovalTarget] = [:]

        for target in targets {
            let resolved = resolve(
                target,
                callerDirectory: callerDirectory,
                repositoryPath: repositoryPath,
                worktrees: worktrees,
                branches: branches
            )
            if let existing = resultsByIdentity[resolved.identity] {
                resultsByIdentity[resolved.identity] = Self.appending(target, to: existing)
            } else {
                orderedIdentities.append(resolved.identity)
                resultsByIdentity[resolved.identity] = resolved.target
            }
        }

        return orderedIdentities.compactMap { resultsByIdentity[$0] }
    }

    private func resolve(
        _ target: String,
        callerDirectory: URL?,
        repositoryPath: URL,
        worktrees: [GitWorktreeSnapshot],
        branches: [GitBranchSnapshot]
    ) -> ResolvedInput {
        if let targetPath = existingDirectory(target, relativeTo: callerDirectory) {
            if let worktree = worktree(containing: targetPath, in: worktrees) {
                return ResolvedInput(identity: .worktree(worktree.id), target: .worktree(worktree, inputs: [target]))
            }
            return ResolvedInput(identity: .notFound(target), target: .notFound(target: target, inputs: [target]))
        }

        if let branch = branches.first(where: { $0.name == target }) {
            if let worktree = worktrees.first(where: { WorktreeListingProjector.branchName(in: $0.head) == branch.name }
            ) {
                return ResolvedInput(identity: .worktree(worktree.id), target: .worktree(worktree, inputs: [target]))
            }
            return ResolvedInput(identity: .branch(branch.name), target: .branch(name: branch.name, inputs: [target]))
        }

        let hasSiblingFolder = hasSiblingWorktreeFolder(for: target, repositoryPath: repositoryPath)
        if !hasSiblingFolder {
            return ResolvedInput(
                identity: .alreadyRemoved(target),
                target: .alreadyRemoved(target: target, inputs: [target])
            )
        }
        return ResolvedInput(identity: .notFound(target), target: .notFound(target: target, inputs: [target]))
    }

    private func existingDirectory(_ target: String, relativeTo callerDirectory: URL?) -> URL? {
        let unresolvedPath: URL
        if target.hasPrefix("/") {
            unresolvedPath = URL(fileURLWithPath: target)
        } else if let callerDirectory {
            unresolvedPath = callerDirectory.appending(path: target, directoryHint: .isDirectory)
        } else {
            return nil
        }
        let canonicalPath = unresolvedPath.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: canonicalPath.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return canonicalPath
    }

    private func worktree(containing path: URL, in worktrees: [GitWorktreeSnapshot]) -> GitWorktreeSnapshot? {
        worktrees.first { snapshot in
            let rootPath = snapshot.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path
            return Self.contains(rootPath: rootPath, candidatePath: path.path)
        }
    }

    private func hasSiblingWorktreeFolder(for target: String, repositoryPath: URL) -> Bool {
        guard case .success(let branchName) = WorktreeBranchName.validated(target),
            let siblingPath = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repositoryPath,
                branchName: branchName
            )
        else {
            return false
        }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: siblingPath.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func contains(rootPath: String, candidatePath: String) -> Bool {
        candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func appending(_ target: String, to existing: WorktreeRemovalTarget) -> WorktreeRemovalTarget {
        switch existing {
        case .worktree(let snapshot, let inputs):
            .worktree(snapshot, inputs: inputs + [target])
        case .branch(let name, let inputs):
            .branch(name: name, inputs: inputs + [target])
        case .alreadyRemoved(let resolvedTarget, let inputs):
            .alreadyRemoved(target: resolvedTarget, inputs: inputs + [target])
        case .notFound(let resolvedTarget, let inputs):
            .notFound(target: resolvedTarget, inputs: inputs + [target])
        }
    }
}
