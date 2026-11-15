import AgentStudioInfrastructure
import CryptoKit
import Darwin
import Dispatch
import Foundation

enum ScrollbackPreparedWrite: Sendable {
    case unchanged
    case invalidUTF8
    case keepPrevious
    case staged(URL, byteCount: Int)
}

private enum SnapshotFileReadResult {
    case bytes(Data)
    case absent
    case failed(ScrollbackUnreadableReason)
}

/// Bounded file work lands on GCD, so callers never park a cooperative-pool
/// thread. Neither snapshot content nor filesystem errors are logged.
enum ScrollbackStoreFileAccess {
    @concurrent
    nonisolated
        static func load(_ snapshotURL: URL, byteCap: Int) async -> ScrollbackLoadResult
    {
        do {
            return try await performFileIO {
                switch readFileBytes(snapshotURL, byteCap: byteCap) {
                case .absent: return .absent
                case .failed(let reason): return .unreadable(reason)
                case .bytes(let bytes):
                    if let reason = validationFailure(bytes, byteCap: byteCap) { return .unreadable(reason) }
                    return .present(bytes)
                }
            }
        } catch { return .unreadable(.readFailed(errno: EIO)) }
    }

    @concurrent
    nonisolated
        static func prepare(_ capture: Data, snapshotURL: URL, byteCap: Int) async throws -> ScrollbackPreparedWrite
    {
        try await performFileIO {
            let trimmed = ScrollbackPersistedForm.trimmingIncompleteUTF8Suffix(capture)
            guard String(data: trimmed, encoding: .utf8) != nil else { return .invalidUTF8 }
            guard !trimmed.isEmpty else { return .unchanged }
            let alternateScreen: Bool
            do {
                alternateScreen = try ScrollbackPersistedForm.isAlternateScreenCapture(trimmed)
            } catch {
                // The whole capture was validated above; decoding failure
                // still rejects through the same typed invalid-output path.
                return .invalidUTF8
            }
            guard !alternateScreen else { return .keepPrevious }
            let persisted = ScrollbackPersistedForm.make(trimmed, byteCap: byteCap)
            guard validationFailure(persisted, byteCap: byteCap) == nil else { return .invalidUTF8 }
            let digest = SHA256.hash(data: persisted)
            if case .bytes(let existing) = readFileBytes(snapshotURL, byteCap: byteCap),
                SHA256.hash(data: existing) == digest
            {
                return .unchanged
            }
            let directory = snapshotURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporaryURL = directory.appending(
                path: ".\(snapshotURL.lastPathComponent).\(UUIDv7.generate().uuidString).tmp")
            try writeOwnerOnly(persisted, to: temporaryURL)
            return .staged(temporaryURL, byteCount: persisted.count)
        }
    }

    /// Synchronous only to keep check-and-rename in the caller actor's one
    /// commit step. No file contents are read or written here.
    static func commit(_ temporaryURL: URL, to snapshotURL: URL) throws {
        guard Darwin.rename(temporaryURL.path, snapshotURL.path) == 0 else { throw currentPOSIXError() }
    }

    @concurrent
    nonisolated
        static func discard(_ temporaryURL: URL) async
    {
        try? await performFileIO { _ = Darwin.unlink(temporaryURL.path) }
    }

    @concurrent
    nonisolated
        static func delete(_ snapshotURLs: [URL]) async throws
    {
        try await performFileIO {
            var firstError: POSIXError?
            for snapshotURL in snapshotURLs {
                if Darwin.unlink(snapshotURL.path) != 0, errno != ENOENT, firstError == nil {
                    firstError = currentPOSIXError()
                }
            }
            if let firstError { throw firstError }
        }
    }

    /// Both publication and load admit the same persisted byte domain.
    private static func validationFailure(_ bytes: Data, byteCap: Int) -> ScrollbackUnreadableReason? {
        guard !bytes.isEmpty else { return .empty }
        guard bytes.count <= byteCap else { return .oversized }
        let body =
            bytes.starts(with: ScrollbackPersistedForm.resetPrefix)
            ? Data(bytes.dropFirst(ScrollbackPersistedForm.resetPrefix.count)) : bytes
        return String(data: body, encoding: .utf8) == nil ? .invalidUTF8 : nil
    }

    private static func readFileBytes(_ url: URL, byteCap: Int) -> SnapshotFileReadResult {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .absent : .failed(.readFailed(errno: errno)) }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { return .failed(.readFailed(errno: errno)) }
        guard information.st_mode & S_IFMT == S_IFREG else { return .failed(.notRegularFile) }
        guard information.st_size <= Int64(byteCap) else { return .failed(.oversized) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: min(byteCap + 1, AppPolicies.Restore.snapshotReadChunkByteCount))
        while true {
            let remaining = byteCap - bytes.count
            let readCount = min(buffer.count, remaining + 1)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, readCount) }
            if count > 0 {
                guard count <= remaining else { return .failed(.oversized) }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return .bytes(bytes)
            } else if errno != EINTR {
                return .failed(.readFailed(errno: errno))
            }
        }
    }

    private static func writeOwnerOnly(_ bytes: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var completed = false
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            if !completed { _ = Darwin.unlink(url.path) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw currentPOSIXError() }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw POSIXError(.EIO)
                } else if errno != EINTR {
                    throw currentPOSIXError()
                }
            }
        }
        let closeResult = Darwin.close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { throw currentPOSIXError() }
        completed = true
    }

    private static func currentPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    @concurrent
    nonisolated
        private static func performFileIO<FileValue: Sendable>(
            _ operation: @escaping @Sendable () throws -> FileValue
        ) async throws -> FileValue
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
