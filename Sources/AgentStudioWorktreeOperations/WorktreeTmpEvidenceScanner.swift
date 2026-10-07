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

        guard Self.fileType(at: worktreeRoot.path) == .typeDirectory else {
            return .unknown(path: temporaryRoot)
        }

        let temporaryAttributes: [FileAttributeKey: Any]
        do {
            temporaryAttributes = try FileManager.default.attributesOfItem(atPath: temporaryRoot.path)
        } catch {
            return Self.isMissingItem(error) ? .empty : .unknown(path: temporaryRoot)
        }
        guard Self.fileType(in: temporaryAttributes) == .typeDirectory else {
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

    private static func fileType(at path: String) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return fileType(in: attributes)
    }

    private static func fileType(in attributes: [FileAttributeKey: Any]) -> FileAttributeType? {
        attributes[.type] as? FileAttributeType
    }

    private static func isMissingItem(_ error: Error) -> Bool {
        let foundationError = error as NSError
        if foundationError.domain == NSCocoaErrorDomain,
            foundationError.code == CocoaError.Code.fileNoSuchFile.rawValue
                || foundationError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        {
            return true
        }

        if foundationError.domain == NSPOSIXErrorDomain,
            POSIXErrorCode(rawValue: Int32(foundationError.code)) == .ENOENT
        {
            return true
        }

        if let underlyingError = foundationError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingItem(underlyingError)
        }
        return false
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
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            } catch {
                throw ScanFailure(path: child)
            }

            if Self.fileType(in: attributes) == .typeDirectory {
                try scanDirectory(
                    child,
                    worktreeRoot: worktreeRoot,
                    temporaryRoot: temporaryRoot,
                    summary: &summary
                )
                continue
            }

            guard let size = attributes[.size] as? NSNumber else { throw ScanFailure(path: child) }
            let (byteCount, overflow) = summary.byteCount.addingReportingOverflow(max(0, size.int64Value))
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
