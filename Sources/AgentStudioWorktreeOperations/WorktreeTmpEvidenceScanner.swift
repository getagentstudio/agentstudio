import Darwin
import Foundation

package enum WorktreeTmpEvidenceScanResult: Sendable, Equatable {
    case empty
    case nonEmpty(fileCount: Int, byteCount: Int64, firstPaths: [String])
    case unknown(path: URL)
}

package struct WorktreeTmpEvidenceScanner: Sendable {
    package init() {}

    @concurrent
    package func scan(worktreePath: URL) async -> WorktreeTmpEvidenceScanResult {
        let worktreeRoot = worktreePath.standardizedFileURL
        let temporaryRoot = worktreeRoot.appending(path: "tmp", directoryHint: .isDirectory)

        guard Self.fileType(at: worktreeRoot.path) == S_IFDIR else {
            return .unknown(path: temporaryRoot)
        }

        var temporaryMetadata = stat()
        let temporaryStatus = temporaryRoot.path.withCString { lstat($0, &temporaryMetadata) }
        guard temporaryStatus == 0 else {
            return errno == ENOENT ? .empty : .unknown(path: temporaryRoot)
        }
        guard temporaryMetadata.st_mode & S_IFMT == S_IFDIR else {
            return .unknown(path: temporaryRoot)
        }

        do {
            var summary = ScanSummary()
            try Self.scanDirectory(
                temporaryRoot,
                worktreeRoot: worktreeRoot,
                temporaryRoot: temporaryRoot,
                summary: &summary
            )
            guard summary.fileCount > 0 else { return .empty }
            return .nonEmpty(
                fileCount: summary.fileCount,
                byteCount: summary.byteCount,
                firstPaths: summary.firstPaths
            )
        } catch let failure as ScanFailure {
            return .unknown(path: failure.path)
        } catch {
            return .unknown(path: temporaryRoot)
        }
    }

    private static func fileType(at path: String) -> mode_t? {
        var metadata = stat()
        let result = path.withCString { lstat($0, &metadata) }
        guard result == 0 else { return nil }
        return metadata.st_mode & S_IFMT
    }

    private static func scanDirectory(
        _ directory: URL,
        worktreeRoot: URL,
        temporaryRoot: URL,
        summary: inout ScanSummary
    ) throws {
        let childNames: [String]
        do {
            childNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw ScanFailure(path: directory)
        }

        for childName in childNames {
            let child = directory.appending(path: childName)
            var metadata = stat()
            let result = child.path.withCString { lstat($0, &metadata) }
            guard result == 0 else { throw ScanFailure(path: child) }

            if metadata.st_mode & S_IFMT == S_IFDIR {
                try scanDirectory(
                    child,
                    worktreeRoot: worktreeRoot,
                    temporaryRoot: temporaryRoot,
                    summary: &summary
                )
                continue
            }

            let (byteCount, overflow) = summary.byteCount.addingReportingOverflow(Int64(max(0, metadata.st_size)))
            guard !overflow else { throw ScanFailure(path: child) }
            summary.byteCount = byteCount
            summary.fileCount += 1

            if summary.firstPaths.count < WorktreeLifecyclePolicy.firstPathsLimit {
                let relativeToWorktree = String(child.standardizedFileURL.path.dropFirst(worktreeRoot.path.count + 1))
                summary.firstPaths.append(relativeToWorktree)
            }
        }
    }
}

private struct ScanSummary {
    var fileCount = 0
    var byteCount: Int64 = 0
    var firstPaths: [String] = []
}

private struct ScanFailure: Error {
    let path: URL
}
