import Foundation
import os.log

enum BridgeWorktreeFileRootAccessError: String, Error, Equatable, Sendable {
    case missingRoot = "missing_root"
    case unreadable
    case refused

    var retryable: Bool { self != .refused }

    var safeMessage: String {
        switch self {
        case .missingRoot: "The File root is unavailable. Restore it, then retry."
        case .unreadable: "The File root or range cannot be read. Check access, then retry."
        case .refused: "Choose an accessible directory as the File root."
        }
    }
}

enum BridgeWorktreeFileEntryKind: Equatable, Sendable {
    case directory
    case regularFile
    case other
}

/// Filesystem access is a production dependency, including on the manifest path.
struct BridgeWorktreeFileDirectoryReader: Sendable {
    let entryKind: @Sendable (URL) throws -> BridgeWorktreeFileEntryKind
    let directoryEntries: @Sendable (URL) throws -> [URL]

    static let foundation = Self(
        entryKind: { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { return .directory }
            if values.isRegularFile == true { return .regularFile }
            return .other
        },
        directoryEntries: { url in
            try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [])
        })
}

private let bridgeFileRootAccessLogger = Logger(subsystem: "com.agentstudio", category: "BridgeFileRootAccess")

enum BridgeWorktreeFileRootAccess {
    @concurrent
    static func validateRoot(
        _ rootURL: URL,
        reader: BridgeWorktreeFileDirectoryReader = .foundation
    ) async throws(BridgeWorktreeFileRootAccessError) {
        try validateRootSynchronously(rootURL, reader: reader)
    }

    static func validateRootSynchronously(
        _ rootURL: URL,
        reader: BridgeWorktreeFileDirectoryReader
    ) throws(BridgeWorktreeFileRootAccessError) {
        try validateRootKindSynchronously(rootURL, reader: reader)
        _ = try directoryEntries(rootURL, reader: reader, isRoot: true)
    }

    static func validateRootKindSynchronously(
        _ rootURL: URL, reader: BridgeWorktreeFileDirectoryReader
    ) throws(BridgeWorktreeFileRootAccessError) {
        let kind = try entryKind(rootURL, reader: reader, isRoot: true)
        guard kind == .directory else {
            recordFailure(.refused)
            throw .refused
        }
    }

    static func entryKind(
        _ url: URL, reader: BridgeWorktreeFileDirectoryReader, isRoot: Bool
    ) throws(BridgeWorktreeFileRootAccessError) -> BridgeWorktreeFileEntryKind {
        do { return try reader.entryKind(url) } catch {
            throw failure(for: error, isRoot: isRoot)
        }
    }

    static func directoryEntries(
        _ url: URL, reader: BridgeWorktreeFileDirectoryReader, isRoot: Bool
    ) throws(BridgeWorktreeFileRootAccessError) -> [URL] {
        do { return try reader.directoryEntries(url) } catch {
            throw failure(for: error, isRoot: isRoot)
        }
    }

    static func isMissing(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(cocoaError.code)
            || cocoaError.domain == NSPOSIXErrorDomain && cocoaError.code == Int(ENOENT)
    }

    static func failure(for error: any Error, isRoot: Bool) -> BridgeWorktreeFileRootAccessError {
        let failure =
            (error as? BridgeWorktreeFileRootAccessError)
            ?? (isRoot && isMissing(error) ? .missingRoot : .unreadable)
        recordFailure(failure)
        return failure
    }

    private static func recordFailure(_ failure: BridgeWorktreeFileRootAccessError) {
        // Only this closed category is logged; Foundation paths/errors never escape.
        bridgeFileRootAccessLogger.error("File access failed cause=\(failure.rawValue, privacy: .public)")
    }
}
