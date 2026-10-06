import Foundation

package enum WorktreeEvidenceArchiveResult: Sendable, Equatable {
    case archived(path: URL, fileCount: Int, skippedSpecialFiles: [String])
    case partialCopy(path: URL)
}

package struct WorktreeEvidenceArchiver: Sendable {
    private enum EntryKind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case specialFile
    }

    private struct Entry: Equatable {
        let relativePath: String
        let kind: EntryKind
        let size: Int64
    }

    package init() {}

    package func archive(source: URL, destination: URL) -> WorktreeEvidenceArchiveResult {
        let fileManager = FileManager.default
        let normalizedSource = source.standardizedFileURL
        let normalizedDestination = destination.standardizedFileURL

        guard !fileManager.fileExists(atPath: normalizedDestination.path),
            let sourceEntries = entries(at: normalizedSource)
        else {
            return .partialCopy(path: normalizedDestination)
        }

        do {
            try fileManager.createDirectory(
                at: normalizedDestination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: normalizedDestination, withIntermediateDirectories: false)
            for entry in sourceEntries {
                let sourceEntry = normalizedSource.appending(path: entry.relativePath)
                let destinationEntry = normalizedDestination.appending(path: entry.relativePath)
                switch entry.kind {
                case .directory:
                    try fileManager.createDirectory(at: destinationEntry, withIntermediateDirectories: false)
                case .regularFile:
                    try fileManager.copyItem(at: sourceEntry, to: destinationEntry)
                case .symbolicLink:
                    let target = try fileManager.destinationOfSymbolicLink(atPath: sourceEntry.path)
                    try fileManager.createSymbolicLink(atPath: destinationEntry.path, withDestinationPath: target)
                case .specialFile:
                    continue
                }
            }
            guard let destinationEntries = entries(at: normalizedDestination),
                Self.verify(
                    sourceEntries: sourceEntries,
                    destinationEntries: destinationEntries,
                    sourceRoot: normalizedSource,
                    destinationRoot: normalizedDestination
                )
            else {
                return .partialCopy(path: normalizedDestination)
            }
            return .archived(
                path: normalizedDestination,
                fileCount: sourceEntries.filter { $0.kind != .directory && $0.kind != .specialFile }.count,
                skippedSpecialFiles:
                    sourceEntries
                    .filter { $0.kind == .specialFile }
                    .map(\.relativePath)
            )
        } catch {
            return .partialCopy(path: normalizedDestination)
        }
    }

    private func entries(at root: URL) -> [Entry]? {
        guard itemType(at: root) == .typeDirectory else { return nil }
        var result: [Entry] = []
        guard collectEntries(in: root, relativeTo: root, result: &result) else { return nil }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func collectEntries(in directory: URL, relativeTo root: URL, result: inout [Entry]) -> Bool {
        let childNames: [String]
        do {
            childNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            return false
        }

        for childName in childNames {
            let child = directory.appending(path: childName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                let type = attributes[.type] as? FileAttributeType,
                let relativePath = relativePath(from: root, to: child)
            else {
                return false
            }

            if type == .typeDirectory {
                result.append(Entry(relativePath: relativePath, kind: .directory, size: 0))
                guard collectEntries(in: child, relativeTo: root, result: &result) else { return false }
            } else if type == .typeRegular || type == .typeSymbolicLink {
                guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else { return false }
                let kind: EntryKind = type == .typeRegular ? .regularFile : .symbolicLink
                result.append(Entry(relativePath: relativePath, kind: kind, size: size))
            } else {
                result.append(Entry(relativePath: relativePath, kind: .specialFile, size: 0))
            }
        }
        return true
    }

    private func itemType(at path: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }

    private func relativePath(from root: URL, to child: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.starts(with: rootComponents), childComponents.count > rootComponents.count else {
            return nil
        }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func verify(
        sourceEntries: [Entry],
        destinationEntries: [Entry],
        sourceRoot: URL,
        destinationRoot: URL
    ) -> Bool {
        let copiedSourceEntries = sourceEntries.filter { $0.kind != .specialFile }
        guard copiedSourceEntries == destinationEntries else { return false }
        for entry in copiedSourceEntries where entry.kind != .directory {
            let source = sourceRoot.appending(path: entry.relativePath)
            let destination = destinationRoot.appending(path: entry.relativePath)
            switch entry.kind {
            case .directory:
                continue
            case .regularFile:
                guard filesContainSameBytes(at: source, and: destination) else { return false }
            case .symbolicLink:
                guard
                    let sourceTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path),
                    let destinationTarget = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: destination.path),
                    sourceTarget == destinationTarget
                else {
                    return false
                }
            case .specialFile:
                continue
            }
        }
        return true
    }

    private static func filesContainSameBytes(at source: URL, and destination: URL) -> Bool {
        guard let sourceHandle = try? FileHandle(forReadingFrom: source),
            let destinationHandle = try? FileHandle(forReadingFrom: destination)
        else {
            return false
        }
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        while true {
            let sourceChunk: Data
            let destinationChunk: Data
            do {
                sourceChunk = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
                destinationChunk = try destinationHandle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                return false
            }
            guard sourceChunk == destinationChunk else { return false }
            if sourceChunk.isEmpty { return true }
        }
    }
}
