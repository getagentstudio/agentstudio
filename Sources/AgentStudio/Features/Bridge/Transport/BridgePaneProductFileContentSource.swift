import CryptoKit
import Darwin
import Foundation

struct BridgePaneProductFileDescriptorMaterialization: Sendable {
    let payload: BridgeProductFileDescriptorReadyPayload
}

struct BridgePaneProductFileMaterializationRequest: Sendable {
    let relativePath: String
    let rootURL: URL
    let row: BridgeWorktreeTreeRowMetadata
    let source: BridgeProductFileSourceIdentity
}

struct BridgePaneProductFileContentReadPlan: Equatable, Sendable {
    let descriptor: BridgeProductFileContentDescriptor
    let relativePath: String
    let rootURL: URL
}

protocol BridgePaneProductFileContentReading: Sendable {
    func nextChunk(maximumByteCount: Int) async throws -> Data?
    func close() async
}

typealias BridgePaneProductFileDescriptorMaterializer =
    @Sendable (BridgePaneProductFileMaterializationRequest) async throws
    -> BridgePaneProductFileDescriptorMaterialization

typealias BridgePaneProductFileContentReaderFactory =
    @Sendable (BridgePaneProductFileContentReadPlan) async throws
    -> any BridgePaneProductFileContentReading

enum BridgePaneProductFileContentSource {
    private static let metadataScanChunkByteCount = 128 * 1024
    private static let binaryClassificationByteCount = BridgeProductWireContract.maximumContentBytes

    static func materialize(
        _ request: BridgePaneProductFileMaterializationRequest
    ) async throws -> BridgePaneProductFileDescriptorMaterialization {
        // File I/O and complete metadata scanning stay outside the provider actor executor.
        // swiftlint:disable:next no_task_detached
        let materializationTask = Task.detached(priority: .userInitiated) {
            try materializeSynchronously(
                rootURL: request.rootURL,
                relativePath: request.relativePath,
                row: request.row,
                source: request.source
            )
        }
        do {
            return try await withTaskCancellationHandler(
                operation: {
                    let materialization = try await materializationTask.value
                    try Task.checkCancellation()
                    return materialization
                },
                onCancel: {
                    materializationTask.cancel()
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let containmentError as BridgeSourcePathContainmentError {
            let unavailableReason: BridgeProductFileDescriptorUnavailableReason =
                switch containmentError {
                case .invalidRoot, .invalidSelector, .outsideRoot:
                    .outsideScope
                case .notRegularFile:
                    .unreadable
                }
            return try unavailableMaterialization(request, reason: unavailableReason)
        } catch {
            return try unavailableMaterialization(request, reason: .unreadable)
        }
    }

    static func openReadSession(
        _ plan: BridgePaneProductFileContentReadPlan
    ) async throws -> any BridgePaneProductFileContentReading {
        try await openReadSession(
            plan,
            beforeOpeningResolvedFile: { _ in },
            afterOpeningFileDescriptor: { _ in }
        )
    }

    static func openReadSession(
        _ plan: BridgePaneProductFileContentReadPlan,
        beforeOpeningResolvedFile: @escaping @Sendable (URL) throws -> Void,
        afterOpeningFileDescriptor: @escaping @Sendable (Int32) -> Void
    ) async throws -> any BridgePaneProductFileContentReading {
        // swiftlint:disable:next no_task_detached
        let openTask = Task.detached(priority: .userInitiated) {
            let openedFile = try openValidatedRegularFile(
                rootURL: plan.rootURL,
                relativePath: plan.relativePath,
                beforeOpeningResolvedFile: beforeOpeningResolvedFile,
                afterOpeningFileDescriptor: afterOpeningFileDescriptor
            )
            guard openedFile.byteCount == plan.descriptor.declaredByteLength else {
                try? openedFile.fileHandle.close()
                throw BridgePaneProductFileContentSourceError.sourceChanged
            }
            return BridgePaneProductFileContentReadSession(fileHandle: openedFile.fileHandle)
        }
        return try await withTaskCancellationHandler(
            operation: {
                let session = try await openTask.value
                do {
                    try Task.checkCancellation()
                    return session
                } catch {
                    await session.close()
                    throw error
                }
            },
            onCancel: {
                openTask.cancel()
            }
        )
    }

    private static func materializeSynchronously(
        rootURL: URL,
        relativePath: String,
        row: BridgeWorktreeTreeRowMetadata,
        source: BridgeProductFileSourceIdentity
    ) throws -> BridgePaneProductFileDescriptorMaterialization {
        let openedFile = try openValidatedRegularFile(
            rootURL: rootURL,
            relativePath: relativePath,
            beforeOpeningResolvedFile: { _ in },
            afterOpeningFileDescriptor: { _ in }
        )
        defer { try? openedFile.fileHandle.close() }
        let scan = try scanCompleteFile(
            openedFile.fileHandle,
            initialIdentity: openedFile.identity
        )
        let fileId = row.fileId ?? stableFileId(relativePath)
        let fileExtension = nonempty(URL(fileURLWithPath: relativePath).pathExtension)
        let availability: BridgeProductFileDescriptorAvailability
        let encoding: BridgeProductFileEncoding?
        let payloadByteCount: Int
        let payloadLineCount: Int
        let totalLineCount: Int?
        let virtualizedExtentKind: BridgeProductFileVirtualizedExtentKind
        if scan.isBinary {
            availability = .binary
            encoding = nil
            payloadByteCount = 0
            payloadLineCount = 0
            totalLineCount = nil
            virtualizedExtentKind = .unavailable
        } else if !scan.isValidUTF8 {
            availability = .unavailable(.unsupportedEncoding)
            encoding = nil
            payloadByteCount = 0
            payloadLineCount = 0
            totalLineCount = nil
            virtualizedExtentKind = .unavailable
        } else {
            let window = try BridgeProductFileContentWindow(
                maximumBytes: scan.byteCount,
                maximumLines: scan.lineCount
            )
            let descriptor = try BridgeProductFileContentDescriptor(
                declaredByteLength: scan.byteCount,
                descriptorId: stableDescriptorId(
                    relativePath: relativePath,
                    sourceSHA256: scan.sha256
                ),
                expectedSha256: scan.sha256,
                fileId: fileId,
                maximumBytes: scan.byteCount,
                source: source,
                window: window
            )
            availability = .available(descriptor)
            encoding = .utf8
            payloadByteCount = scan.byteCount
            payloadLineCount = scan.lineCount
            totalLineCount = scan.lineCount
            virtualizedExtentKind = .exactLineCount
        }
        let payload = try BridgeProductFileDescriptorReadyPayload(
            availability: availability,
            encoding: encoding,
            endsMidLine: false,
            endsWithNewline: encoding == nil ? false : scan.endsWithNewline,
            estimatedContentHeightPixels: nil,
            fileExtension: fileExtension,
            fileId: fileId,
            language: language(for: fileExtension),
            modifiedAtUnixMilliseconds: scan.modifiedAtUnixMilliseconds,
            path: relativePath,
            payloadByteCount: payloadByteCount,
            payloadLineCount: payloadLineCount,
            rowId: row.rowId,
            sizeBytes: scan.byteCount,
            source: source,
            totalLineCount: totalLineCount,
            truncationKind: .complete,
            virtualizedExtentKind: virtualizedExtentKind
        )
        return .init(payload: payload)
    }

    private static func scanCompleteFile(
        _ fileHandle: FileHandle,
        initialIdentity: BridgePaneProductOpenedFileIdentity
    ) throws -> BridgePaneProductCompleteFileScan {
        var classifiedByteCount = 0
        var byteCount = 0
        var hasher = SHA256()
        var isBinary = false
        var lastByte: UInt8?
        var lineFeedCount = 0
        var utf8Validator = BridgeStrictIncrementalUTF8Validator()

        while let chunk = try fileHandle.read(upToCount: metadataScanChunkByteCount),
            !chunk.isEmpty
        {
            try Task.checkCancellation()
            let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(chunk.count)
            guard !overflowed,
                nextByteCount <= BridgeProductWireContract.maximumContentStreamBytes
            else {
                throw BridgePaneProductFileContentSourceError.sourceTooLarge
            }
            let remainingClassificationBytes = max(
                binaryClassificationByteCount - classifiedByteCount,
                0
            )
            if remainingClassificationBytes > 0,
                chunk.prefix(remainingClassificationBytes).contains(0)
            {
                isBinary = true
            }
            classifiedByteCount += min(chunk.count, remainingClassificationBytes)
            hasher.update(data: chunk)
            utf8Validator.consume(chunk)
            lineFeedCount += chunk.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "\n") { count += 1 }
            }
            lastByte = chunk.last
            byteCount = nextByteCount
        }
        try Task.checkCancellation()
        let finalIdentity = try openedFileIdentity(fileHandle)
        guard finalIdentity == initialIdentity,
            byteCount == finalIdentity.byteCount
        else {
            throw BridgePaneProductFileContentSourceError.sourceChanged
        }
        let endsWithNewline = lastByte == UInt8(ascii: "\n")
        let lineCount = byteCount == 0 ? 0 : lineFeedCount + (endsWithNewline ? 0 : 1)
        return BridgePaneProductCompleteFileScan(
            byteCount: byteCount,
            endsWithNewline: endsWithNewline,
            isBinary: isBinary,
            isValidUTF8: utf8Validator.isCompleteAndValid,
            lineCount: lineCount,
            modifiedAtUnixMilliseconds: finalIdentity.modifiedAtUnixMilliseconds,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func unavailableMaterialization(
        _ request: BridgePaneProductFileMaterializationRequest,
        reason: BridgeProductFileDescriptorUnavailableReason
    ) throws -> BridgePaneProductFileDescriptorMaterialization {
        let fileId = request.row.fileId ?? stableFileId(request.relativePath)
        let fileExtension = nonempty(URL(fileURLWithPath: request.relativePath).pathExtension)
        let payload = try BridgeProductFileDescriptorReadyPayload(
            availability: .unavailable(reason),
            encoding: nil,
            endsMidLine: false,
            endsWithNewline: false,
            estimatedContentHeightPixels: nil,
            fileExtension: fileExtension,
            fileId: fileId,
            language: language(for: fileExtension),
            modifiedAtUnixMilliseconds: nil,
            path: request.relativePath,
            payloadByteCount: 0,
            payloadLineCount: 0,
            rowId: request.row.rowId,
            sizeBytes: max(request.row.sizeBytes ?? 0, 0),
            source: request.source,
            totalLineCount: nil,
            truncationKind: .complete,
            virtualizedExtentKind: .unavailable
        )
        return .init(payload: payload)
    }

    private static func openValidatedRegularFile(
        rootURL: URL,
        relativePath: String,
        beforeOpeningResolvedFile: @Sendable (URL) throws -> Void,
        afterOpeningFileDescriptor: @Sendable (Int32) -> Void
    ) throws -> BridgePaneProductOpenedRegularFile {
        let resolvedFileURL = try BridgeSourcePathContainment.resolveRegularFile(
            rootURL: rootURL,
            relativePath: relativePath
        )
        try beforeOpeningResolvedFile(resolvedFileURL)
        let fileHandle = try FileHandle(forReadingFrom: resolvedFileURL)
        afterOpeningFileDescriptor(fileHandle.fileDescriptor)
        do {
            let identity = try openedFileIdentity(fileHandle)
            let openedFileURL = try descriptorResolvedFileURL(fileHandle)
            var pathStatus = stat()
            guard openedFileURL.path.utf8.elementsEqual(resolvedFileURL.path.utf8),
                stat(openedFileURL.path, &pathStatus) == 0,
                isRegularFile(pathStatus),
                pathStatus.st_dev == identity.device,
                pathStatus.st_ino == identity.inode
            else {
                throw BridgePaneProductFileContentSourceError.sourceChanged
            }
            return BridgePaneProductOpenedRegularFile(
                byteCount: identity.byteCount,
                fileHandle: fileHandle,
                identity: identity
            )
        } catch {
            try? fileHandle.close()
            throw error
        }
    }

    private static func descriptorResolvedFileURL(
        _ fileHandle: FileHandle
    ) throws -> URL {
        var descriptorInformation = vnode_fdinfowithpath()
        let expectedByteCount = Int32(MemoryLayout.size(ofValue: descriptorInformation))
        guard
            proc_pidfdinfo(
                getpid(),
                fileHandle.fileDescriptor,
                PROC_PIDFDVNODEPATHINFO,
                &descriptorInformation,
                expectedByteCount
            ) == expectedByteCount
        else {
            throw BridgePaneProductFileContentSourceError.sourceChanged
        }
        let descriptorPath = withUnsafePointer(to: &descriptorInformation.pvip.vip_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        guard !descriptorPath.isEmpty else {
            throw BridgePaneProductFileContentSourceError.sourceChanged
        }
        return URL(fileURLWithPath: descriptorPath).standardizedFileURL
    }

    private static func openedFileIdentity(
        _ fileHandle: FileHandle
    ) throws -> BridgePaneProductOpenedFileIdentity {
        var status = stat()
        guard Darwin.fstat(fileHandle.fileDescriptor, &status) == 0,
            isRegularFile(status),
            status.st_size >= 0,
            status.st_size <= off_t(BridgeProductWireContract.maximumContentStreamBytes)
        else {
            throw BridgeSourcePathContainmentError.notRegularFile
        }
        let modifiedAtUnixMilliseconds = max(
            Int(status.st_mtimespec.tv_sec) * 1000
                + Int(status.st_mtimespec.tv_nsec) / 1_000_000,
            0
        )
        return BridgePaneProductOpenedFileIdentity(
            byteCount: Int(status.st_size),
            device: status.st_dev,
            inode: status.st_ino,
            modifiedAtUnixMilliseconds: modifiedAtUnixMilliseconds
        )
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func stableFileId(_ relativePath: String) -> String {
        "worktree-file-\(sha256(relativePath).prefix(32))"
    }

    static func stableDescriptorId(
        relativePath: String,
        sourceSHA256: String
    ) -> String {
        "file-content-\(sha256("\(relativePath):\(sourceSHA256)").prefix(32))"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func language(for fileExtension: String?) -> String? {
        switch fileExtension {
        case "swift": "swift"
        case "ts", "tsx": "typescript"
        case "js", "jsx": "javascript"
        case "json": "json"
        case "md": "markdown"
        case .some(let fileExtension): fileExtension
        case nil: nil
        }
    }

    private static func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

private actor BridgePaneProductFileContentReadSession: BridgePaneProductFileContentReading {
    private var fileHandle: FileHandle?

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    deinit {
        try? fileHandle?.close()
    }

    func nextChunk(maximumByteCount: Int) async throws -> Data? {
        guard maximumByteCount > 0,
            maximumByteCount <= BridgeProductWireContract.maximumContentDataPayloadBytes,
            let fileHandle
        else {
            throw BridgePaneProductFileContentSourceError.invalidReadRequest
        }
        try Task.checkCancellation()
        // swiftlint:disable:next no_task_detached
        let readTask = Task.detached(priority: .userInitiated) {
            try fileHandle.read(upToCount: maximumByteCount)
        }
        let chunk = try await withTaskCancellationHandler(
            operation: {
                let chunk = try await readTask.value
                try Task.checkCancellation()
                return chunk
            },
            onCancel: {
                readTask.cancel()
            }
        )
        guard let chunk, !chunk.isEmpty else { return nil }
        return chunk
    }

    func close() {
        guard let fileHandle else { return }
        self.fileHandle = nil
        try? fileHandle.close()
    }
}

private struct BridgePaneProductCompleteFileScan {
    let byteCount: Int
    let endsWithNewline: Bool
    let isBinary: Bool
    let isValidUTF8: Bool
    let lineCount: Int
    let modifiedAtUnixMilliseconds: Int
    let sha256: String
}

private struct BridgePaneProductOpenedRegularFile {
    let byteCount: Int
    let fileHandle: FileHandle
    let identity: BridgePaneProductOpenedFileIdentity
}

private struct BridgePaneProductOpenedFileIdentity: Equatable {
    let byteCount: Int
    let device: dev_t
    let inode: ino_t
    let modifiedAtUnixMilliseconds: Int
}

private struct BridgeStrictIncrementalUTF8Validator {
    private var continuationByteCount = 0
    private var continuationMaximum: UInt8 = 0xbf
    private var continuationMinimum: UInt8 = 0x80
    private(set) var isValid = true

    var isCompleteAndValid: Bool {
        isValid && continuationByteCount == 0
    }

    mutating func consume(_ data: Data) {
        guard isValid else { return }
        for byte in data {
            consume(byte)
            if !isValid { return }
        }
    }

    private mutating func consume(_ byte: UInt8) {
        if continuationByteCount > 0 {
            guard (continuationMinimum...continuationMaximum).contains(byte) else {
                isValid = false
                return
            }
            continuationByteCount -= 1
            continuationMinimum = 0x80
            continuationMaximum = 0xbf
            return
        }
        switch byte {
        case 0x00...0x7f:
            return
        case 0xc2...0xdf:
            beginScalar(continuationByteCount: 1)
        case 0xe0:
            beginScalar(continuationByteCount: 2, firstMinimum: 0xa0)
        case 0xe1...0xec, 0xee...0xef:
            beginScalar(continuationByteCount: 2)
        case 0xed:
            beginScalar(continuationByteCount: 2, firstMaximum: 0x9f)
        case 0xf0:
            beginScalar(continuationByteCount: 3, firstMinimum: 0x90)
        case 0xf1...0xf3:
            beginScalar(continuationByteCount: 3)
        case 0xf4:
            beginScalar(continuationByteCount: 3, firstMaximum: 0x8f)
        default:
            isValid = false
        }
    }

    private mutating func beginScalar(
        continuationByteCount: Int,
        firstMinimum: UInt8 = 0x80,
        firstMaximum: UInt8 = 0xbf
    ) {
        self.continuationByteCount = continuationByteCount
        continuationMinimum = firstMinimum
        continuationMaximum = firstMaximum
    }
}

enum BridgePaneProductFileContentSourceError: Error {
    case invalidReadRequest
    case sourceChanged
    case sourceTooLarge
}
