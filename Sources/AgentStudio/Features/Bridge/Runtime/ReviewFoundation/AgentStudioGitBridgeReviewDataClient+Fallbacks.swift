import AgentStudioGit
import AgentStudioInfrastructure
import CryptoKit
import Foundation

extension AgentStudioGitBridgeReviewDataClient {
    func shouldRecoverWithStatusFallback(
        from failure: BridgeProviderFailure,
        baseTarget: GitDiffTarget,
        headTarget: GitDiffTarget
    ) -> Bool {
        guard case .providerFailed(let message) = failure,
            headTarget == .workingTree || headTarget == .index,
            baseTarget == .head || baseTarget == .index || baseTarget.kind == .commit
        else {
            return false
        }

        let normalizedMessage = message.lowercased()
        guard
            normalizedMessage.contains("gitdataplane:libgit2failure")
                || normalizedMessage.contains("git.libgit2failure")
        else {
            return false
        }
        return isRecoverableWorkingTreeReadFailureMessage(normalizedMessage)
    }

    func isRecoverableWorkingTreeReadFailureMessage(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        guard normalizedMessage.contains("libgit2failure") else {
            return false
        }
        return normalizedMessage.contains("reason=filereadfailed")
            || normalizedMessage.contains("reason=filestatfailed")
            || normalizedMessage.contains("reason=directorytraversalfailure")
            || normalizedMessage.contains("reason=directorytraversalfailed")
    }

    func statusFallbackChangedFiles(
        baseTarget: GitDiffTarget,
        headTarget: GitDiffTarget,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> [BridgeEndpointChangedFile] {
        let fallbackSnapshot = try await loadStatusFallbackSnapshot(freshnessKey: freshnessKey)
        var changedFiles: [BridgeEndpointChangedFile] = []
        for entry in fallbackSnapshot.status.entries.sorted(by: { $0.path < $1.path }) {
            guard !entry.ignored,
                entry.untracked || entry.indexState != nil || entry.worktreeState != nil
            else {
                continue
            }
            guard
                let changedFile = try await statusFallbackChangedFile(
                    entry: entry,
                    baseTarget: baseTarget,
                    headTarget: headTarget,
                    freshnessKey: freshnessKey
                )
            else {
                continue
            }
            changedFiles.append(changedFile)
        }
        if changedFiles.isEmpty, let fullStatusFailure = fallbackSnapshot.fullStatusFailure {
            throw fullStatusFailure
        }
        return changedFiles
    }

    func loadStatusFallbackSnapshot(
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> StatusFallbackSnapshot {
        do {
            let status = try await loadGitStatus(
                GitStatusOptions(includeIgnored: false, includeUntracked: true),
                freshnessKey: freshnessKey
            )
            return StatusFallbackSnapshot(status: status, fullStatusFailure: nil)
        } catch let failure as BridgeProviderFailure {
            guard shouldRetryStatusFallbackWithoutUntracked(from: failure) else {
                throw failure
            }
            let trackedStatus = try await loadGitStatus(
                GitStatusOptions(includeIgnored: false, includeUntracked: false),
                freshnessKey: freshnessKey
            )
            return StatusFallbackSnapshot(status: trackedStatus, fullStatusFailure: failure)
        }
    }

    func shouldRetryStatusFallbackWithoutUntracked(from failure: BridgeProviderFailure) -> Bool {
        guard case .providerFailed(let message) = failure else {
            return false
        }
        return isRecoverableWorkingTreeReadFailureMessage(message)
    }

    func treeFilesystemFallbackFailure(
        reason: String,
        statusFailure: BridgeProviderFailure,
        treeFailure: BridgeProviderFailure? = nil
    ) -> BridgeProviderFailure {
        let statusReason = providerFailureSummary(statusFailure)
        if let treeFailure {
            let treeReason = providerFailureSummary(treeFailure)
            return .providerFailed(
                message: "gitDataPlane:treeFilesystemFallback:\(reason):status=\(statusReason):tree=\(treeReason)"
            )
        }
        return .providerFailed(message: "gitDataPlane:treeFilesystemFallback:\(reason):status=\(statusReason)")
    }

    func providerFailureSummary(_ failure: BridgeProviderFailure) -> String {
        switch failure {
        case .providerFailed(let message):
            return providerFailureReason(from: message)
        case .providerUnavailable:
            return "providerUnavailable"
        case .sourceCapacityDeferred:
            return "sourceCapacityDeferred"
        case .unavailableEndpoint(let endpointId):
            return "unavailableEndpoint:\(endpointId)"
        case .missingContent(let handleId):
            return "missingContent:\(handleId)"
        case .contentHashMismatch(let handleId, _, _):
            return "contentHashMismatch:\(handleId)"
        case .oversizedContent(let handleId, _):
            return "oversizedContent:\(handleId)"
        case .binaryContent(let handleId):
            return "binaryContent:\(handleId)"
        case .staleReviewGeneration:
            return "staleReviewGeneration"
        }
    }

    func providerFailureReason(from message: String) -> String {
        let normalizedMessage = message.lowercased()
        if normalizedMessage.hasPrefix("gitdataplane:") {
            let prefixLength = "gitDataPlane:".count
            let suffix = String(message.dropFirst(prefixLength))
            return sanitizedGitDataPlaneFailureReason(from: suffix)
        }
        if normalizedMessage.contains("filereadfailed") {
            return "fileReadFailed"
        }
        if normalizedMessage.contains("filestatfailed") {
            return "fileStatFailed"
        }
        if normalizedMessage.contains("directorytraversal") {
            return "directoryTraversalFailed"
        }
        if normalizedMessage.contains("unsupportedtreeread") || normalizedMessage.contains("tree reads") {
            return "unsupportedTreeRead"
        }
        if normalizedMessage.contains("notfound") || normalizedMessage.contains("not found") {
            return "notFound"
        }
        if normalizedMessage.contains("unsupported") {
            return "unsupported"
        }
        if normalizedMessage.contains("unexpected") {
            return "unexpected"
        }
        return "providerError"
    }

    func sanitizedGitDataPlaneFailureReason(from suffix: String) -> String {
        let parts = suffix.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else {
            return "git.providerError"
        }
        switch kind {
        case "libgit2Failure":
            let code = parts.first { $0.hasPrefix("code=") }
            let klass = parts.first { $0.hasPrefix("klass=") }
            let reason = parts.first { $0.hasPrefix("reason=") }
            return (["git.libgit2Failure", code, klass, reason].compactMap { $0 })
                .joined(separator: ":")
        case "contentTooLarge":
            let sizeBytes = parts.first { $0.hasPrefix("sizeBytes=") }
            return (["git.contentTooLarge", sizeBytes].compactMap { $0 }).joined(separator: ":")
        case "pathEscapesRepository", "worktreeNotFound", "worktreeNotPrunable",
            "unsafeWorktreeRemoval", "processFailed", "processTimedOut", "processCancelled",
            "processOutputTooLarge", "fileReadFailed", "fileStatFailed",
            "directoryTraversalFailed", "unsupportedTreeRead":
            return "git.\(kind)"
        case "unexpected":
            let errorType = parts.dropFirst().first
            return (["git.unexpected", errorType].compactMap { $0 }).joined(separator: ":")
        default:
            return "git.providerError"
        }
    }

    func statusFallbackChangedFile(
        entry: GitStatusEntry,
        baseTarget: GitDiffTarget,
        headTarget: GitDiffTarget,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeEndpointChangedFile? {
        let changeKind = bridgeChangeKind(entry)
        let basePath = entry.previousPath ?? entry.path
        let headPath = entry.path
        let baseMetadata: FallbackContentMetadata?
        let headMetadata: FallbackContentMetadata?

        switch changeKind {
        case .added, .copied:
            baseMetadata = nil
            headMetadata = try await fallbackContentMetadata(
                entry: entry,
                changeKind: changeKind,
                target: headTarget,
                path: headPath,
                role: "head",
                freshnessKey: freshnessKey
            )
        case .deleted:
            baseMetadata = try await fallbackContentMetadata(
                entry: entry,
                changeKind: changeKind,
                target: baseTarget,
                path: basePath,
                role: "base",
                freshnessKey: freshnessKey
            )
            headMetadata = nil
        case .modified, .renamed:
            baseMetadata = try await fallbackContentMetadata(
                entry: entry,
                changeKind: changeKind,
                target: baseTarget,
                path: basePath,
                role: "base",
                freshnessKey: freshnessKey
            )
            headMetadata = try await fallbackContentMetadata(
                entry: entry,
                changeKind: changeKind,
                target: headTarget,
                path: headPath,
                role: "head",
                freshnessKey: freshnessKey
            )
        }

        let effectiveMetadata = headMetadata ?? baseMetadata
        guard let effectiveMetadata else { return nil }
        return BridgeEndpointChangedFile(
            fileId: statusFallbackFileId(entry: entry, changeKind: changeKind),
            path: headPath,
            oldPath: changeKind == .renamed ? entry.previousPath : nil,
            changeKind: changeKind,
            language: language(for: headPath),
            fileExtension: fileExtension(for: headPath),
            sizeBytes: effectiveMetadata.sizeBytes,
            oldContentHash: baseMetadata?.contentHash,
            newContentHash: headMetadata?.contentHash,
            contentHashAlgorithm: effectiveMetadata.contentHashAlgorithm,
            additions: 0,
            deletions: 0,
            isBinary: effectiveMetadata.isBinary,
            mimeType: mimeType(for: headPath, isBinary: effectiveMetadata.isBinary)
        )
    }

    func fallbackContentMetadata(
        entry: GitStatusEntry,
        changeKind: BridgeFileChangeKind,
        target: GitDiffTarget,
        path: String,
        role: String,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> FallbackContentMetadata {
        if let contentMetadata = try await contentMetadataIfAvailable(
            target: target,
            path: path,
            freshnessKey: freshnessKey
        ) {
            return contentMetadata
        }
        return syntheticFallbackContentMetadata(
            entry: entry,
            changeKind: changeKind,
            target: target,
            path: path,
            role: role
        )
    }

    func syntheticFallbackContentMetadata(
        entry: GitStatusEntry,
        changeKind: BridgeFileChangeKind,
        target: GitDiffTarget,
        path: String,
        role: String
    ) -> FallbackContentMetadata {
        let identity = [
            "status-fallback-content",
            entry.previousPath ?? "none",
            entry.path,
            changeKind.rawValue,
            target.kind.rawValue,
            target.identifier ?? "none",
            role,
        ].joined(separator: ":")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return FallbackContentMetadata(
            sizeBytes: fallbackFilesystemSizeBytes(target: target, path: path) ?? 0,
            isBinary: false,
            contentHash: "status-fallback:\(digest.prefix(32))",
            contentHashAlgorithm: "status-fallback-sha256"
        )
    }

    func fallbackFilesystemSizeBytes(target: GitDiffTarget, path: String) -> Int? {
        guard target == .workingTree else { return nil }
        let fileURL = repositoryPath.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return byteCount(fileSize.int64Value)
    }

    func treeFilesystemFallbackChangedFiles(
        baseTarget: GitDiffTarget,
        headTarget: GitDiffTarget,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> [BridgeEndpointChangedFile] {
        guard headTarget == .workingTree || headTarget == .index else {
            return []
        }
        let baseRevision = try gitRevisionTarget(for: baseTarget)
        let baseEntries = try await recursiveGitTreeEntries(
            revision: baseRevision,
            path: nil,
            freshnessKey: freshnessKey
        )
        var changedFiles: [BridgeEndpointChangedFile] = []
        for entry in baseEntries where !entry.isTree {
            let path = entry.path
            let baseMetadata = treeEntryContentMetadata(entry)
            if headTarget == .workingTree {
                let fileURL = repositoryPath.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    changedFiles.append(
                        treeFilesystemFallbackChangedFile(
                            path: path,
                            changeKind: .deleted,
                            baseMetadata: baseMetadata,
                            headMetadata: nil
                        )
                    )
                    continue
                }
            }
            let headMetadata =
                filesystemContentMetadata(path: path)
                ?? syntheticTreeFilesystemFallbackHeadMetadata(path: path, headTarget: headTarget)
            guard baseMetadata.contentHash != headMetadata.contentHash else { continue }
            changedFiles.append(
                treeFilesystemFallbackChangedFile(
                    path: path,
                    changeKind: .modified,
                    baseMetadata: baseMetadata,
                    headMetadata: headMetadata
                )
            )
        }
        return changedFiles.sorted { $0.path < $1.path }
    }

    func treeEntryContentMetadata(_ entry: GitTreeEntry) -> FallbackContentMetadata {
        FallbackContentMetadata(
            sizeBytes: byteCount(entry.sizeBytes),
            isBinary: false,
            contentHash: entry.oid,
            contentHashAlgorithm: "git-blob-sha1"
        )
    }

    func filesystemContentMetadata(path: String) -> FallbackContentMetadata? {
        let fileURL = repositoryPath.appendingPathComponent(path)
        guard let sizeBytes = fallbackFilesystemSizeBytes(target: .workingTree, path: path),
            let contentHash = try? streamGitBlobSHA1ContentHash(fileURL: fileURL, sizeBytes: sizeBytes)
        else {
            return nil
        }
        return FallbackContentMetadata(
            sizeBytes: sizeBytes,
            isBinary: false,
            contentHash: contentHash,
            contentHashAlgorithm: "git-blob-sha1"
        )
    }

    func syntheticTreeFilesystemFallbackHeadMetadata(
        path: String,
        headTarget: GitDiffTarget
    ) -> FallbackContentMetadata {
        let identity = [
            "tree-filesystem-fallback-content",
            path,
            headTarget.kind.rawValue,
            headTarget.identifier ?? "none",
        ].joined(separator: ":")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return FallbackContentMetadata(
            sizeBytes: fallbackFilesystemSizeBytes(target: headTarget, path: path) ?? 0,
            isBinary: false,
            contentHash: "tree-fs-fallback:\(digest.prefix(32))",
            contentHashAlgorithm: "tree-filesystem-fallback-sha256"
        )
    }

    func gitBlobSHA1ContentHash(_ data: Data) -> String {
        var blobData = Data("blob \(data.count)\0".utf8)
        blobData.append(data)
        return Insecure.SHA1.hash(data: blobData).map { String(format: "%02x", $0) }.joined()
    }

    func streamGitBlobSHA1ContentHash(fileURL: URL, sizeBytes: Int) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(sizeBytes)\0".utf8))
        while true {
            let chunk = try fileHandle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func recursiveGitTreeEntries(
        revision: GitRevisionTarget,
        path: String?,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> [GitTreeEntry] {
        let tree = try await loadGitTree(
            GitTreeReadRequest(
                repositoryPath: repositoryPath,
                revision: revision,
                path: path
            ),
            freshnessKey: freshnessKey
        )
        var entries: [GitTreeEntry] = []
        for entry in tree.entries {
            if entry.isTree {
                entries.append(
                    contentsOf: try await recursiveGitTreeEntries(
                        revision: revision,
                        path: entry.path,
                        freshnessKey: freshnessKey
                    )
                )
            } else {
                entries.append(entry)
            }
        }
        return entries
    }

    func treeFilesystemFallbackChangedFile(
        path: String,
        changeKind: BridgeFileChangeKind,
        baseMetadata: FallbackContentMetadata?,
        headMetadata: FallbackContentMetadata?
    ) -> BridgeEndpointChangedFile {
        let effectiveMetadata = headMetadata ?? baseMetadata
        return BridgeEndpointChangedFile(
            fileId: treeFilesystemFallbackFileId(path: path, changeKind: changeKind),
            path: path,
            oldPath: nil,
            changeKind: changeKind,
            language: language(for: path),
            fileExtension: fileExtension(for: path),
            sizeBytes: effectiveMetadata?.sizeBytes ?? 0,
            oldContentHash: baseMetadata?.contentHash,
            newContentHash: headMetadata?.contentHash,
            contentHashAlgorithm: effectiveMetadata?.contentHashAlgorithm ?? "sha256",
            additions: 0,
            deletions: 0,
            isBinary: effectiveMetadata?.isBinary ?? false,
            mimeType: mimeType(for: path, isBinary: effectiveMetadata?.isBinary ?? false)
        )
    }

    func contentMetadataIfAvailable(
        target: GitDiffTarget,
        path: String,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> FallbackContentMetadata? {
        do {
            let content = try await loadGitContent(
                GitContentRequest(
                    repositoryPath: repositoryPath,
                    target: target,
                    path: path,
                    maxSizeBytes: Int64(AppPolicies.Bridge.contentMaxBytesPerItem)
                ),
                handle: nil,
                freshnessKey: freshnessKey
            )
            return FallbackContentMetadata(
                sizeBytes: content.data.count,
                isBinary: content.isBinary,
                contentHash: content.contentHash,
                contentHashAlgorithm: content.contentHashAlgorithm
            )
        } catch BridgeProviderFailure.providerUnavailable, BridgeProviderFailure.missingContent,
            BridgeProviderFailure.oversizedContent, BridgeProviderFailure.binaryContent,
            BridgeProviderFailure.providerFailed, BridgeProviderFailure.sourceCapacityDeferred
        {
            return nil
        }
    }
}
