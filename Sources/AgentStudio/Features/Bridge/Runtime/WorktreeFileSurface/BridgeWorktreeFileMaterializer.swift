import CryptoKit
import Foundation

struct BridgeWorktreeFileMaterializationRequest: Sendable {
    let rootURL: URL
    let openedSource: BridgeWorktreeFileOpenedSource
    let directoryReader: BridgeWorktreeFileDirectoryReader

    init(
        rootURL: URL, openedSource: BridgeWorktreeFileOpenedSource,
        directoryReader: BridgeWorktreeFileDirectoryReader = .foundation
    ) {
        self.rootURL = rootURL
        self.openedSource = openedSource
        self.directoryReader = directoryReader
    }
}

struct BridgeWorktreeTreeRowWindowBatch: Sendable {
    let discoveredRowCount: Int
    let isFinalWindow: Bool
    let rows: [BridgeWorktreeTreeRowMetadata]
    let startIndex: Int
}

struct BridgeWorktreeRefreshedTreeRows: Sendable {
    let rows: [BridgeWorktreeTreeRowMetadata]
    let missingPaths: Set<String>
}

enum BridgeWorktreeFileMaterializer {
    static func canMaterializeDemandPath(
        _ relativePath: String,
        openedSource: BridgeWorktreeFileOpenedSource
    ) -> Bool {
        guard isPublishedTreePath(relativePath, ignorePolicy: openedSource.ignorePolicy) else {
            return false
        }
        return isWithinDemandScope(relativePath, openedSource: openedSource)
    }

    /// Interest paths are validated for safety and scope only: the manifest
    /// index is the publication authority for interest (spec: interest is
    /// index-members-only). Index members include published ancestors of
    /// force-added files that gitignore RULES alone would misclassify as
    /// ignored, so the rules check must not gate interest.
    static func isInterestEligibleDemandPath(
        _ relativePath: String,
        openedSource: BridgeWorktreeFileOpenedSource
    ) -> Bool {
        guard isSafeDemandPath(relativePath) else {
            return false
        }
        return isWithinDemandScope(relativePath, openedSource: openedSource)
    }

    private static func isWithinDemandScope(
        _ relativePath: String,
        openedSource: BridgeWorktreeFileOpenedSource
    ) -> Bool {
        let pathScope = openedSource.canonicalPathScope
        guard !pathScope.isEmpty else {
            return true
        }
        return pathScope.contains { scopedPath in
            scopedPath == "."
                || relativePath == scopedPath
                || relativePath.hasPrefix("\(scopedPath)/")
        }
    }

    static func materializeTreeRowWindows(
        request: BridgeWorktreeFileMaterializationRequest,
        afterCount: Int,
        windowSize: Int
    ) -> AsyncThrowingStream<BridgeWorktreeTreeRowWindowBatch, Error> {
        AsyncThrowingStream { continuation in
            // swiftlint:disable:next no_task_detached
            let task = Task.detached(priority: .utility) {
                do {
                    try materializeTreeRowWindowsSynchronously(
                        request: request,
                        afterCount: afterCount,
                        windowSize: windowSize
                    ) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Freshness stat-truth for metadata interest: rebuilds rows for the
    /// requested manifest-member paths from current filesystem facts, and
    /// reports paths whose stat failed so the caller can emit a removal
    /// delta. Runs off the MainActor; never enumerates the worktree.
    static func refreshTreeRows(
        rootURL: URL,
        relativePaths: Set<String>,
        includeAncestorDirectories: Bool = false
    ) async -> BridgeWorktreeRefreshedTreeRows {
        // swiftlint:disable:next no_task_detached
        await Task.detached(priority: .userInitiated) {
            var rows: [BridgeWorktreeTreeRowMetadata] = []
            var emittedPaths = Set<String>()
            var missingPaths = Set<String>()

            func appendRow(_ row: BridgeWorktreeTreeRowMetadata) {
                guard emittedPaths.insert(row.path).inserted else { return }
                rows.append(row)
            }

            for relativePath in relativePaths {
                let fileURL = rootURL.appending(path: relativePath)
                // fileExists resolves symlinks, so published symlinked files
                // refresh as file rows instead of being misclassified as
                // missing (which would emit a wrong removeRows delta).
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                else {
                    missingPaths.insert(relativePath)
                    continue
                }
                if includeAncestorDirectories {
                    try? appendAncestorRowsThrowing(for: relativePath) { row in
                        appendRow(row)
                    }
                }
                if isDirectory.boolValue {
                    appendRow(directoryTreeRow(relativePath: relativePath))
                } else if let row = try? fileTreeRow(fileURL: fileURL, relativePath: relativePath) {
                    appendRow(row)
                }
            }
            return BridgeWorktreeRefreshedTreeRows(rows: rows, missingPaths: missingPaths)
        }.value
    }

    private static func materializeTreeRowWindowsSynchronously(
        request: BridgeWorktreeFileMaterializationRequest,
        afterCount: Int,
        windowSize: Int,
        yield: (BridgeWorktreeTreeRowWindowBatch) -> Void
    ) throws {
        guard afterCount >= 0, windowSize > 0 else {
            return
        }
        try BridgeWorktreeFileRootAccess.validateRootSynchronously(request.rootURL, reader: request.directoryReader)
        var rowsByPath: [String: BridgeWorktreeTreeRowMetadata] = [:]
        var orderedRowCount = 0
        var windowRows: [BridgeWorktreeTreeRowMetadata] = []
        var windowStartIndex: Int?

        func flushWindowIfNeeded(force: Bool = false) {
            guard !windowRows.isEmpty, force || windowRows.count >= windowSize else {
                return
            }
            yield(
                BridgeWorktreeTreeRowWindowBatch(
                    discoveredRowCount: orderedRowCount,
                    isFinalWindow: force,
                    rows: windowRows,
                    startIndex: windowStartIndex ?? orderedRowCount - windowRows.count
                )
            )
            windowRows.removeAll(keepingCapacity: true)
            windowStartIndex = nil
        }

        func appendRow(_ row: BridgeWorktreeTreeRowMetadata) throws {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard rowsByPath[row.path] == nil else {
                return
            }
            let rowIndex = orderedRowCount
            rowsByPath[row.path] = row
            orderedRowCount += 1
            guard rowIndex >= afterCount else {
                return
            }
            if windowRows.isEmpty {
                windowStartIndex = rowIndex
            }
            windowRows.append(row)
            flushWindowIfNeeded()
        }

        try forEachInitialTreeRowPath(
            rootURL: request.rootURL,
            canonicalPathScope: request.openedSource.canonicalPathScope,
            ignorePolicy: request.openedSource.ignorePolicy,
            directoryReader: request.directoryReader,
            maxPathCount: nil
        ) { relativePath in
            try appendAncestorRowsThrowing(for: relativePath) { row in
                try appendRow(row)
            }
            let fileURL = request.rootURL.appending(path: relativePath)
            // fileExists resolves symlinks, so tracked symlinked files
            // publish as file rows at their link path (a symlinked
            // directory publishes as a non-expanded directory row — the
            // manifest never registers children under a link path).
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    try appendRow(directoryTreeRow(relativePath: relativePath))
                } else {
                    try appendRow(try fileTreeRow(fileURL: fileURL, relativePath: relativePath))
                }
            }
            return true
        }
        try BridgeWorktreeFileRootAccess.validateRootKindSynchronously(
            request.rootURL, reader: request.directoryReader)
        flushWindowIfNeeded(force: true)
    }

    private static func forEachInitialTreeRowPath(
        rootURL: URL,
        canonicalPathScope: [String],
        ignorePolicy: BridgeWorktreeFileIgnorePolicy,
        directoryReader: BridgeWorktreeFileDirectoryReader,
        maxPathCount: Int?,
        visit: (String) throws -> Bool
    ) throws {
        let scopedPaths =
            canonicalPathScope.isEmpty
            ? ["."]
            : canonicalPathScope
        var seenPaths = Set<String>()
        var visitedPathCount = 0

        func visitIfNeeded(_ relativePath: String) throws -> Bool {
            guard !seenPaths.contains(relativePath) else {
                return true
            }
            seenPaths.insert(relativePath)
            if let maxPathCount, visitedPathCount >= maxPathCount {
                return false
            }
            visitedPathCount += 1
            return try visit(relativePath)
        }

        for scopedPath in scopedPaths {
            if let maxPathCount, visitedPathCount >= maxPathCount {
                break
            }
            let scopedURL = scopedPath == "." ? rootURL : rootURL.appending(path: scopedPath)
            let kind: BridgeWorktreeFileEntryKind
            do {
                kind = try directoryReader.entryKind(scopedURL)
            } catch {
                if scopedPath != ".", BridgeWorktreeFileRootAccess.isMissing(error) {
                    try BridgeWorktreeFileRootAccess.validateRootSynchronously(rootURL, reader: directoryReader)
                    continue
                }
                throw BridgeWorktreeFileRootAccess.failure(for: error, isRoot: scopedPath == ".")
            }
            if kind == .regularFile {
                if isPublishedTreePath(scopedPath, ignorePolicy: ignorePolicy) {
                    guard try visitIfNeeded(scopedPath) else {
                        return
                    }
                }
                continue
            }
            guard kind == .directory else {
                continue
            }
            if scopedPath != "." && isPublishedTreePath(scopedPath, ignorePolicy: ignorePolicy) {
                guard try visitIfNeeded(scopedPath) else {
                    return
                }
            }
            if scopedPath != "." && isNestedGitWorktreeRoot(scopedURL, rootURL: rootURL) {
                continue
            }
            try enumerateTreeRowPaths(
                rootURL: rootURL,
                scopedURL: scopedURL,
                ignorePolicy: ignorePolicy,
                directoryReader: directoryReader,
                maxCount: maxPathCount.map { max($0 - visitedPathCount, 0) }
            ) { relativePath in
                try visitIfNeeded(relativePath)
            }
        }
    }

    private static func enumerateTreeRowPaths(
        rootURL: URL,
        scopedURL: URL,
        ignorePolicy: BridgeWorktreeFileIgnorePolicy,
        directoryReader: BridgeWorktreeFileDirectoryReader,
        maxCount: Int?,
        visit: (String) throws -> Bool
    ) throws {
        if let maxCount, maxCount <= 0 {
            return
        }
        // Git worktrees enumerate from the publishable manifest instead of
        // walking the filesystem: ignored directories are never visited and
        // only published paths are statted. The walk below remains the
        // non-git fallback.
        if let publishableFilePaths = ignorePolicy.publishableFilePaths {
            _ = try BridgeWorktreeFileRootAccess.directoryEntries(
                scopedURL, reader: directoryReader, isRoot: scopedURL == rootURL)
            let isRootScope =
                scopedURL.standardizedFileURL.path == rootURL.standardizedFileURL.path
            try enumerateTreeRowPaths(
                publishableFilePaths: publishableFilePaths,
                scopedRelativePath: isRootScope ? nil : relativePath(fileURL: scopedURL, rootURL: rootURL),
                visit: { relativePath in
                    let childURL = rootURL.appending(path: relativePath)
                    let kind: BridgeWorktreeFileEntryKind
                    do { kind = try directoryReader.entryKind(childURL) } catch {
                        if BridgeWorktreeFileRootAccess.isMissing(error) { return true }
                        throw BridgeWorktreeFileRootAccess.failure(for: error, isRoot: false)
                    }
                    if kind == .directory {
                        _ = try BridgeWorktreeFileRootAccess.directoryEntries(
                            childURL, reader: directoryReader, isRoot: false)
                    }
                    return try visit(relativePath)
                })
            return
        }

        var pathCount = 0
        var pendingDirectories = [scopedURL]
        while !pendingDirectories.isEmpty {
            if let maxCount, pathCount >= maxCount {
                break
            }
            let directoryURL = pendingDirectories.removeFirst()
            let childURLs = try BridgeWorktreeFileRootAccess.directoryEntries(
                directoryURL, reader: directoryReader, isRoot: directoryURL == rootURL)
            for fileURL in childURLs.sorted(by: compareFileDiscoveryOrder) {
                if let maxCount, pathCount >= maxCount {
                    return
                }
                let relativePath = relativePath(fileURL: fileURL, rootURL: rootURL)
                if !isPublishedTreePath(relativePath, ignorePolicy: ignorePolicy) {
                    continue
                }
                let kind: BridgeWorktreeFileEntryKind
                do { kind = try directoryReader.entryKind(fileURL) } catch {
                    if BridgeWorktreeFileRootAccess.isMissing(error) { continue }
                    throw BridgeWorktreeFileRootAccess.failure(for: error, isRoot: false)
                }
                if kind == .regularFile {
                    pathCount += 1
                    guard try visit(relativePath) else {
                        return
                    }
                } else if kind == .directory {
                    pathCount += 1
                    guard try visit(relativePath) else {
                        return
                    }
                    if !isNestedGitWorktreeRoot(fileURL, rootURL: rootURL) {
                        pendingDirectories.append(fileURL)
                    }
                }
            }
        }
    }

    /// Exact tree row count (files plus implied directories, plus scope
    /// rows) for a publishable manifest, mirroring the enumeration and the
    /// caller's scope-row emission so the open response can carry
    /// `exactPathCount` before the first frame — the scrollbar is born at
    /// its final length instead of snapping from an estimate.
    static func exactTreeRowCount(
        publishableFilePaths: Set<String>,
        canonicalPathScope: [String]
    ) -> Int {
        let scopedRelativePaths: [String?] =
            canonicalPathScope.isEmpty ? [nil] : canonicalPathScope.map { $0 }
        var seenPaths = Set<String>()
        for scopedRelativePath in scopedRelativePaths {
            if let scopedRelativePath {
                seenPaths.insert(scopedRelativePath)
                if publishableFilePaths.contains(scopedRelativePath) {
                    continue
                }
            }
            try? enumerateTreeRowPaths(
                publishableFilePaths: publishableFilePaths,
                scopedRelativePath: scopedRelativePath
            ) { relativePath in
                seenPaths.insert(relativePath)
                return true
            }
        }
        return seenPaths.count
    }

    /// Breadth-first enumeration over the publishable manifest, matching the
    /// filesystem walk's order exactly: per-directory children (directories
    /// and files interleaved) sorted by last path component, directories
    /// expanded in queue order. Directories exist implicitly as the ancestor
    /// prefixes of published files, so ignored subtrees are never visited.
    private static func enumerateTreeRowPaths(
        publishableFilePaths: Set<String>,
        scopedRelativePath: String?,
        visit: (String) throws -> Bool
    ) throws {
        var childDirectoriesByParent: [String: Set<String>] = [:]
        var childFilesByParent: [String: [String]] = [:]
        let scopePrefix = scopedRelativePath.map { $0 + "/" }
        let scopeRoot = scopedRelativePath ?? ""
        for filePath in publishableFilePaths {
            if let scopedRelativePath {
                guard filePath == scopedRelativePath || filePath.hasPrefix(scopePrefix ?? "") else {
                    continue
                }
                if filePath == scopedRelativePath {
                    // The scope itself is a published file; the caller's
                    // scope loop already visits file scopes directly.
                    continue
                }
            }
            let components = filePath.split(separator: "/").map(String.init)
            var parentPath = ""
            for componentIndex in 0..<max(components.count - 1, 0) {
                let directoryPath =
                    parentPath.isEmpty
                    ? components[componentIndex]
                    : parentPath + "/" + components[componentIndex]
                if directoryPath.count > scopeRoot.count {
                    childDirectoriesByParent[parentPath, default: []].insert(directoryPath)
                }
                parentPath = directoryPath
            }
            childFilesByParent[parentPath, default: []].append(filePath)
        }
        var pendingDirectories = [scopeRoot]
        while !pendingDirectories.isEmpty {
            let directoryPath = pendingDirectories.removeFirst()
            let childDirectories = childDirectoriesByParent[directoryPath] ?? []
            let childFiles = childFilesByParent[directoryPath] ?? []
            let unsortedChildren =
                childDirectories.map { (path: $0, isDirectory: true) }
                + childFiles.map { (path: $0, isDirectory: false) }
            let sortedChildren = unsortedChildren.sorted { lhs, rhs in
                lastPathComponent(lhs.path).utf8
                    .lexicographicallyPrecedes(lastPathComponent(rhs.path).utf8)
            }
            for child in sortedChildren {
                guard try visit(child.path) else {
                    return
                }
                if child.isDirectory {
                    pendingDirectories.append(child.path)
                }
            }
        }
    }

    private static func lastPathComponent(_ relativePath: String) -> String {
        if let separatorIndex = relativePath.lastIndex(of: "/") {
            return String(relativePath[relativePath.index(after: separatorIndex)...])
        }
        return relativePath
    }

    private static func appendAncestorRowsThrowing(
        for relativePath: String,
        appendRow: (BridgeWorktreeTreeRowMetadata) throws -> Void
    ) throws {
        let pathComponents = relativePath.split(separator: "/").map(String.init)
        guard pathComponents.count > 1 else {
            return
        }
        for componentCount in 1..<pathComponents.count {
            let ancestorPath = pathComponents.prefix(componentCount).joined(separator: "/")
            try appendRow(directoryTreeRow(relativePath: ancestorPath))
        }
    }

    // Manifest ordering is deterministic and policy-owned: plain code-unit
    // comparison of sibling names, breadth-first by directory. A generic
    // provider must not encode a specific repository's folder names.
    private static func compareFileDiscoveryOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
    }

    private static func relativePath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard let range = filePath.range(of: prefix, options: [.anchored]) else {
            return fileURL.lastPathComponent
        }
        return String(filePath[range.upperBound...])
    }

    private static func directoryTreeRow(relativePath: String) -> BridgeWorktreeTreeRowMetadata {
        let pathComponents = relativePath.split(separator: "/").map(String.init)
        return BridgeWorktreeTreeRowMetadata(
            rowId: "worktree-directory-\(sha256Hex(Data(relativePath.utf8)).prefix(32))",
            path: relativePath,
            name: pathComponents.last ?? relativePath,
            parentPath: parentPath(for: pathComponents),
            depth: max(pathComponents.count - 1, 0),
            isDirectory: true,
            fileId: nil,
            fileClass: nil,
            sizeBytes: nil,
            lineCount: nil,
            changeStatus: nil
        )
    }

    private static func fileTreeRow(fileURL: URL, relativePath: String) throws -> BridgeWorktreeTreeRowMetadata {
        let pathComponents = relativePath.split(separator: "/").map(String.init)
        let sizeBytes = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let fileId = "worktree-file-\(sha256Hex(Data(relativePath.utf8)).prefix(32))"
        return BridgeWorktreeTreeRowMetadata(
            rowId: "worktree-file-row-\(sha256Hex(Data(relativePath.utf8)).prefix(32))",
            path: relativePath,
            name: pathComponents.last ?? relativePath,
            parentPath: parentPath(for: pathComponents),
            depth: max(pathComponents.count - 1, 0),
            isDirectory: false,
            fileId: String(fileId),
            fileClass: BridgeReviewFileClassifier.classify(
                path: relativePath,
                isBinary: false,
                sizeBytes: sizeBytes
            ),
            sizeBytes: sizeBytes,
            lineCount: nil,
            changeStatus: nil
        )
    }

    private static func parentPath(for pathComponents: [String]) -> String? {
        guard pathComponents.count > 1 else {
            return nil
        }
        return pathComponents.dropLast().joined(separator: "/")
    }

    private static func isGitInternalPath(_ path: String) -> Bool {
        path == ".git" || path.hasPrefix(".git/")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isNestedGitWorktreeRoot(_ directoryURL: URL, rootURL: URL) -> Bool {
        let canonicalDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalDirectoryURL.path != canonicalRootURL.path else {
            return false
        }
        return FileManager.default.fileExists(atPath: canonicalDirectoryURL.appending(path: ".git").path)
    }

    private static func isSafeDemandPath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false, isGitInternalPath(path) == false else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return false
        }
        return true
    }

    // Publication policy is git-truth only (accepted product decision
    // 2026-07-01): repository ignore policy plus structural exclusions
    // (`.git` internals via isSafeDemandPath, nested worktree roots at the
    // enumeration boundary). Hidden dotfiles and generated-dependency
    // directories are published unless gitignored.
    private static func isPublishedTreePath(
        _ path: String,
        ignorePolicy: BridgeWorktreeFileIgnorePolicy
    ) -> Bool {
        isSafeDemandPath(path)
            && !ignorePolicy.isIgnored(relativePath: path)
    }
}
