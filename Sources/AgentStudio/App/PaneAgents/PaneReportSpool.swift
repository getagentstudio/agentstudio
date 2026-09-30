import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Admits the notifications a pane CLI appended while the app was unreachable.
/// One owner-only file per pane is read under the writer's own lock, every line
/// is submitted as late evidence through the IPC sessions admission, and the
/// file is truncated only once nothing is left to retry.
actor PaneReportSpool {
    /// Counts only. No line text, explanation or message ever reaches a log or
    /// telemetry sink from this type.
    struct DrainReport: Equatable, Sendable {
        var admittedLineCount = 0
        var rejectedLineCount = 0
        var malformedLineCount = 0
        var truncatedFileCount = 0
        var retainedFileCount = 0

        var hasWork: Bool {
            admittedLineCount > 0 || rejectedLineCount > 0 || malformedLineCount > 0
                || retainedFileCount > 0
        }

        static func += (lhs: inout Self, rhs: Self) {
            lhs.admittedLineCount += rhs.admittedLineCount
            lhs.rejectedLineCount += rhs.rejectedLineCount
            lhs.malformedLineCount += rhs.malformedLineCount
            lhs.truncatedFileCount += rhs.truncatedFileCount
            lhs.retainedFileCount += rhs.retainedFileCount
        }
    }

    private enum LineOutcome: Equatable, Sendable {
        case admitted
        case rejected
        case malformed
        case retryable
    }

    private static let fileSuffix = ".notifications.ndjson"
    private static let reportMethodName = "session.report"
    private static let messageMethodName = "session.message"
    private static let selfHandle = "self"

    private let admission: any AppIPCSessionsPort
    private let descriptorsByMethodName: [String: IPCAnyMethodDescriptor]
    private let maximumLineBytes: Int

    init(
        admission: any AppIPCSessionsPort,
        maximumLineBytes: Int = AppPolicies.IPC.spoolDrainMaximumLineBytes
    ) throws {
        self.admission = admission
        self.maximumLineBytes = maximumLineBytes
        descriptorsByMethodName = Dictionary(
            uniqueKeysWithValues: try IPCBuiltInMethodCatalog.offlineNotificationDescriptors(
                examples: .init(illustrativeIdentifier: UUIDv7.generate())
            ).map { ($0.metadata.name, $0) }
        )
    }

    func drain(spoolDirectory: URL) async -> DrainReport {
        var report = DrainReport()
        guard let fileNames = await Self.spoolFileNames(in: spoolDirectory) else {
            return report
        }
        for fileName in fileNames.sorted() where fileName.hasSuffix(Self.fileSuffix) {
            guard !Task.isCancelled else { return report }
            guard let paneId = UUID(uuidString: String(fileName.dropLast(Self.fileSuffix.count))) else {
                continue
            }
            let fileReport = await drainFile(
                at: spoolDirectory.appendingPathComponent(fileName),
                paneId: paneId
            )
            report += fileReport
        }
        return report
    }

    /// The exclusive lock is held across admission so a concurrent CLI append
    /// cannot land between reading the lines and truncating the file.
    ///
    /// Every blocking syscall runs off this actor's executor. `flock(LOCK_EX)`
    /// waits for however long the pane's CLI holds the file, and an actor whose
    /// executor is parked in that syscall answers nothing else.
    private func drainFile(at url: URL, paneId: UUID) async -> DrainReport {
        #if canImport(Darwin)
            var report = DrainReport()
            let descriptor = await Self.openForUpdate(path: url.path)
            guard descriptor >= 0 else {
                report.retainedFileCount = 1
                return report
            }
            // Releasing the lock and closing the descriptor never block, so they
            // stay here where a `defer` can guarantee them.
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            guard await Self.acquireExclusiveLock(descriptor) else {
                report.retainedFileCount = 1
                return report
            }
            guard
                let decoded = await Self.readSpoolFile(
                    descriptor: descriptor, maximumLineBytes: maximumLineBytes)
            else {
                report.retainedFileCount = 1
                return report
            }
            report.malformedLineCount += decoded.unreadableLineCount
            var retainedLines: [String] = []
            for (offset, line) in decoded.lines.enumerated() {
                switch await admit(line: line, paneId: paneId) {
                case .admitted: report.admittedLineCount += 1
                case .rejected: report.rejectedLineCount += 1
                case .malformed: report.malformedLineCount += 1
                case .retryable:
                    // Order is the pane's sequence, so a line that must be
                    // retried keeps every line behind it rather than letting a
                    // later one be admitted ahead of it.
                    retainedLines = Array(decoded.lines[offset...])
                }
                guard retainedLines.isEmpty else { break }
            }
            guard retainedLines.isEmpty else {
                // Only the retried lines stay. Replacing instead of leaving the
                // file whole is what stops an admitted record being re-read and
                // re-deduped on every launch, without bound. The file is
                // retained either way: a replacement that could not be made
                // leaves the original whole, and its admitted lines are dropped
                // as duplicate correlations by the next drain rather than
                // admitted twice.
                report.retainedFileCount = 1
                await Self.replaceSpoolFile(at: url, retaining: retainedLines)
                return report
            }
            // The all-admitted case truncates in place rather than renaming an
            // empty replacement. There is nothing left to lose — every line is
            // already durable in Sessions — and keeping one inode means a writer
            // waiting on this lock appends to the file the next drain reads,
            // with no reopen.
            guard await Self.truncateToEmpty(descriptor) else {
                report.retainedFileCount = 1
                return report
            }
            report.truncatedFileCount = 1
            return report
        #else
            return DrainReport(retainedFileCount: 1)
        #endif
    }

    // MARK: - Blocking file work, off the actor's executor

    @concurrent private nonisolated static func spoolFileNames(in directory: URL) async -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    #if canImport(Darwin)
        private struct DecodedSpoolFile {
            let lines: [String]
            /// Lines that can never be admitted because they cannot be read back
            /// as one UTF-8 line within the ceiling, plus a torn trailing line.
            let unreadableLineCount: Int
        }

        @concurrent private nonisolated static func openForUpdate(path: String) async -> Int32 {
            open(path, O_RDWR)
        }

        @concurrent private nonisolated static func acquireExclusiveLock(_ descriptor: Int32) async -> Bool {
            flock(descriptor, LOCK_EX) == 0
        }

        @concurrent private nonisolated static func truncateToEmpty(_ descriptor: Int32) async -> Bool {
            ftruncate(descriptor, 0) == 0
        }

        /// Leaves the path holding exactly `retainedLines`, or holding exactly
        /// what it held before. There is no third outcome, which is the whole
        /// point: rewriting in place cannot promise that.
        ///
        /// An in-place rewrite seeks to zero and overwrites. A failure partway
        /// through leaves the head replaced and the tail stale, and both halves
        /// are notifications nobody can get back — an `lseek`, `write` or
        /// `ftruncate` that reported an error had already destroyed the file it
        /// was rewriting. Writing a replacement and renaming it over the path
        /// either lands whole or never touches the original.
        ///
        /// The cost is one inode change. `flock` holds an open file description
        /// rather than a name, so a writer that opened before the rename wakes
        /// up locking an inode with no directory entry;
        /// `PaneNotificationSpoolWriter` answers that by comparing the inode it
        /// locked against the one the path names and reopening when they differ.
        @concurrent private nonisolated static func replaceSpoolFile(
            at url: URL,
            retaining retainedLines: [String]
        ) async {
            var contents = Data()
            for line in retainedLines {
                contents.append(contentsOf: Array(line.utf8))
                contents.append(0x0a)
            }
            let directoryURL = url.deletingLastPathComponent()
            let replacementURL = directoryURL.appendingPathComponent(
                ".\(url.lastPathComponent).\(UUIDv7.generate().uuidString).replacement"
            )
            let descriptor = open(replacementURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { return }
            let written = writeAllBytes(contents, to: descriptor) && fsync(descriptor) == 0
            close(descriptor)
            guard written, rename(replacementURL.path, url.path) == 0 else {
                unlink(replacementURL.path)
                return
            }
            // The replacement's own bytes are durable, but the directory entry
            // that now points at it is not until the directory is synchronized.
            _ = synchronizeDirectoryEntry(at: directoryURL.path)
        }

        private nonisolated static func writeAllBytes(_ contents: Data, to descriptor: Int32) -> Bool {
            var writtenCount = 0
            while writtenCount < contents.count {
                let result = contents.withUnsafeBytes { pointer -> Int in
                    guard let baseAddress = pointer.baseAddress else { return -1 }
                    return write(
                        descriptor,
                        baseAddress.advanced(by: writtenCount),
                        contents.count - writtenCount
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard result > 0 else { return false }
                writtenCount += result
            }
            return true
        }

        private nonisolated static func synchronizeDirectoryEntry(at path: String) -> Bool {
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return fsync(descriptor) == 0
        }

        @concurrent private nonisolated static func readSpoolFile(
            descriptor: Int32,
            maximumLineBytes: Int
        ) async -> DecodedSpoolFile? {
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { return nil }
            var contents = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let readCount = buffer.withUnsafeMutableBytes { pointer in
                    read(descriptor, pointer.baseAddress, pointer.count)
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                guard readCount > 0 else { break }
                contents.append(contentsOf: buffer[..<readCount])
            }
            return splitLines(in: contents, maximumLineBytes: maximumLineBytes)
        }

        /// Splits the file itself rather than streaming it through the wire frame
        /// decoder: that decoder drops everything still buffered when one frame
        /// exceeds the ceiling, which would wedge every later notification in the
        /// same file behind a line that can never be admitted. Here an unreadable
        /// line is counted and skipped, and its neighbours still drain.
        private nonisolated static func splitLines(
            in contents: Data,
            maximumLineBytes: Int
        ) -> DecodedSpoolFile {
            var lines: [String] = []
            var unreadableLineCount = 0
            var lineStart = contents.startIndex
            while let newlineIndex = contents[lineStart...].firstIndex(of: 0x0a) {
                let rawLine = contents[lineStart..<newlineIndex]
                lineStart = contents.index(after: newlineIndex)
                guard !rawLine.isEmpty else { continue }
                let normalized = rawLine.last == 0x0d ? rawLine.dropLast() : rawLine
                guard normalized.count <= maximumLineBytes,
                    let line = String(data: Data(normalized), encoding: .utf8)
                else {
                    unreadableLineCount += 1
                    continue
                }
                lines.append(line)
            }
            // A line without its terminator is a torn append. It is not a
            // notification anyone can admit, and it must not hold the file.
            if lineStart < contents.endIndex { unreadableLineCount += 1 }
            return DecodedSpoolFile(lines: lines, unreadableLineCount: unreadableLineCount)
        }
    #endif

    /// Eligibility is re-checked against the compiled descriptors: a line that
    /// names an ineligible variant or another method never reaches admission,
    /// whatever wrote it.
    private func admit(line: String, paneId: UUID) async -> LineOutcome {
        guard let request = try? JSONRPCCodec.decodeRequest(line, maxBytes: maximumLineBytes),
            let descriptor = descriptorsByMethodName[request.method],
            let parameters = request.params,
            let rawParameters = try? JSONEncoder().encode(parameters),
            let normalizedParameters = try? descriptor.normalizeParameters(rawParameters)
        else {
            return .malformed
        }
        switch request.method {
        case Self.reportMethodName:
            guard
                let reportParameters = try? JSONDecoder().decode(
                    IPCSessionReportParams.self, from: normalizedParameters.data),
                Self.isOfflineEligible(Self.modelCallVariant(for: reportParameters.kind), in: descriptor),
                Self.resolvesToPane(handle: reportParameters.handle, paneId: paneId)
            else {
                return .malformed
            }
            do {
                _ = try await admission.recordDeliberateReport(paneId: paneId, params: reportParameters)
                return .admitted
            } catch {
                return Self.lineOutcome(for: error)
            }
        case Self.messageMethodName:
            guard
                let messageParameters = try? JSONDecoder().decode(
                    IPCSessionMessageParams.self, from: normalizedParameters.data),
                Self.isOfflineEligible(.message, in: descriptor),
                Self.resolvesToPane(handle: messageParameters.handle, paneId: paneId)
            else {
                return .malformed
            }
            do {
                _ = try await admission.recordAgentMessage(paneId: paneId, params: messageParameters)
                return .admitted
            } catch {
                return Self.lineOutcome(for: error)
            }
        default:
            return .malformed
        }
    }

    /// A duplicate correlation is already durable, so it consumes its line. A
    /// line the admission can never accept — a foreign target, a rejected shape —
    /// consumes its line too.
    ///
    /// `bindingRequired` is neither. The CLI already answered the model "Report
    /// queued.", and a pane that has never bound may still bind: dropping the
    /// line here would turn an accepted notification into a silent loss. It is
    /// retryable, so the file is retained and the next drain tries again.
    private static func lineOutcome(for error: any Error) -> LineOutcome {
        guard let sessionsError = error as? AppIPCSessionsError else { return .retryable }
        switch sessionsError.reason {
        case .correlationConflict:
            return .admitted
        case .targetNotFound, .validationRejected:
            return .rejected
        case .bindingRequired, .ingestionUnavailable:
            return .retryable
        }
    }

    private static func modelCallVariant(for kind: IPCSessionReportKind) -> IPCModelCallVariant {
        switch kind {
        case .needsYou: .needsYou
        case .clearNeedsYou: .needsYouClear
        case .done: .done
        }
    }

    private static func isOfflineEligible(
        _ variant: IPCModelCallVariant,
        in descriptor: IPCAnyMethodDescriptor
    ) -> Bool {
        guard case .modelCallVariants(let variants) = descriptor.metadata.offlineEligibility else {
            return false
        }
        return variants.contains(variant)
    }

    /// The file name is the durable pane identity. A line that targets another
    /// pane was not written by that pane's own CLI.
    private static func resolvesToPane(handle: String, paneId: UUID) -> Bool {
        handle == selfHandle || handle == paneId.uuidString
    }
}
