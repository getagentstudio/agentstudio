import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Ephemeral kernel input. argv0 must never enter the durable observation row.
package struct ForegroundProcessSample: Sendable {
    package let incarnation: ProcessIncarnation
    package let processGroupId: Int32
    package let foregroundGroupId: Int32
    package let argv0: String
}

package struct ForegroundPsPass: Sendable {
    package let samples: [ForegroundProcessSample]
    package let incompleteLeaders: Set<Int32>
    package let leadersWithVanishedRows: Set<Int32>
}

package struct DarwinTerminalForegroundProbe: TerminalForegroundProbing {
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let sessionControl: any ZmxSessionControlling
    private let kernelReader: any TerminalForegroundKernelReading
    private let readSamples: (@Sendable () async throws -> ForegroundPsPass)?
    package init(
        sessionDirectory: String, bootId: String,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        sessionControl: (any ZmxSessionControlling)? = nil,
        readSamples: (@Sendable () async throws -> ForegroundPsPass)? = nil,
        kernelReader: any TerminalForegroundKernelReading = DarwinTerminalForegroundKernelReader()
    ) {
        self.performanceTraceRecorder = performanceTraceRecorder
        self.sessionControl = sessionControl ?? ForegroundZmxSessionControl(directory: sessionDirectory, bootId: bootId)
        self.readSamples = readSamples
        self.kernelReader = kernelReader
    }

    @concurrent nonisolated package func probeForeground(of sessions: [ZmxSessionID]) async throws
        -> [ZmxSessionID: ForegroundSnapshot]
    {
        var identities: [ZmxSessionID: (Data, ZmxSessionIdentity)] = [:]
        for sessionId in Set(sessions) {
            try Task.checkCancellation()
            do {
                if let data = try await sessionControl.observeSessionIdentity(sessionId) {
                    identities[sessionId] = (data, try ZmxSessionIdentity.decode(data))
                }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        guard !identities.isEmpty else { return [:] }
        let pass: ForegroundPsPass
        if let readSamples {
            pass = try await readSamples()
        } else {
            pass = try await Self.readNativeSamples(
                leaders: identities.values.map { $0.1.terminalLeader },
                performanceTraceRecorder: performanceTraceRecorder, kernelReader: kernelReader)
        }
        var snapshots: [ZmxSessionID: ForegroundSnapshot] = [:]
        for (sessionId, captured) in identities {
            let (data, identity) = captured
            // The socket may have disappeared or been replaced during kernel reads.
            // Only a positively unchanged session may contribute a record.
            guard let current = try? await sessionControl.observeSessionIdentity(sessionId), current == data else {
                continue
            }
            let leader = identity.terminalLeader
            let program = Self.classify(
                leader: leader, samples: pass.samples, incompleteLeaders: pass.incompleteLeaders,
                leadersWithVanishedRows: pass.leadersWithVanishedRows)
            let agent = Self.foregroundRows(leader: leader, samples: pass.samples).first {
                Self.agentProgram(argv0: $0.argv0) == program && (program == .claudeCode || program == .codex)
            }
            snapshots[sessionId] = ForegroundSnapshot(
                sessionIdentity: data, foregroundProcess: agent?.incarnation, program: program)
        }
        return snapshots
    }

    package static func classify(
        leader: ProcessIncarnation, samples: [ForegroundProcessSample], incompleteLeaders: Set<Int32>,
        leadersWithVanishedRows: Set<Int32>
    ) -> ForegroundProgram {
        guard !incompleteLeaders.contains(leader.pid) else { return .unknown }
        let foreground = foregroundRows(leader: leader, samples: samples)
        guard !foreground.isEmpty, foreground.allSatisfy({ !$0.argv0.isEmpty }) else { return .unknown }
        for sample in foreground {
            if let agent = agentProgram(argv0: sample.argv0) { return agent }
        }
        guard !leadersWithVanishedRows.contains(leader.pid) else { return .unknown }
        let shells = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh"]
        return foreground.allSatisfy { shells.contains(binaryName($0.argv0)) } ? .shell : .other
    }

    private static func foregroundRows(leader: ProcessIncarnation, samples: [ForegroundProcessSample])
        -> [ForegroundProcessSample]
    {
        guard let shell = samples.first(where: { $0.incarnation == leader }), shell.foregroundGroupId > 0 else {
            return []
        }
        return samples.filter { $0.processGroupId == shell.foregroundGroupId }
    }

    private static func binaryName(_ argv0: String) -> String {
        let basename = (argv0 as NSString).lastPathComponent
        return basename.hasPrefix("-") ? String(basename.dropFirst()) : basename
    }

    private static func agentProgram(argv0: String) -> ForegroundProgram? {
        switch binaryName(argv0) {
        case "claude": .claudeCode
        case "codex": .codex
        default: nil
        }
    }

    /// Discover only requested leaders and their foreground groups. Re-read selected
    /// rows during attribution so regrouping and disappearing processes remain unknown.
    @concurrent nonisolated package static func readNativeSamples(
        leaders: [ProcessIncarnation], performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        kernelReader: any TerminalForegroundKernelReading = DarwinTerminalForegroundKernelReader()
    ) async throws -> ForegroundPsPass {
        let leaderIds = Set(leaders.map(\.pid))
        return try AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundProbe, recorder: performanceTraceRecorder
        ) {
            try Task.checkCancellation()
            var rows: [(pid: Int32, group: Int32, foreground: Int32)] = []
            for leader in leaders where !rows.contains(where: { $0.pid == leader.pid }) {
                try Task.checkCancellation()
                guard case .sample(let sample) = kernelReader.readNativeSample(pid: leader.pid, readArguments: false),
                    sample.incarnation == leader
                else { continue }
                rows.append((leader.pid, sample.processGroupId, sample.foregroundGroupId))
            }
            let foregroundGroups = Set(rows.map(\.foreground).filter { $0 > 0 })
            var incompleteLeaders: Set<Int32> = []
            var failedMemberReads: [Int32: NativeSampleReadResult] = [:]
            for groupId in foregroundGroups {
                let affectedLeaders = rows.filter { leaderIds.contains($0.pid) && $0.foreground == groupId }.map(\.pid)
                guard let members = try readGroupMembers(groupId, kernelReader: kernelReader) else {
                    incompleteLeaders.formUnion(affectedLeaders)
                    continue
                }
                for pid in Set(members) where pid > 0 {
                    try Task.checkCancellation()
                    if let existing = rows.first(where: { $0.pid == pid }) {
                        if existing.group != groupId { incompleteLeaders.formUnion(affectedLeaders) }
                        continue
                    }
                    let read = kernelReader.readNativeSample(pid: pid, readArguments: false)
                    switch read {
                    case .sample(let sample):
                        guard sample.processGroupId == groupId else {
                            incompleteLeaders.formUnion(affectedLeaders)
                            continue
                        }
                        rows.append((pid, sample.processGroupId, sample.foregroundGroupId))
                    case .vanished, .unreadable:
                        // Retain the enumerated membership for the existing per-leader
                        // failure attribution, even when BSD metadata has disappeared.
                        rows.append((pid, groupId, 0))
                        failedMemberReads[pid] = read
                    }
                }
            }
            let pass = try attributeSamples(rows: rows, requestedLeaderPids: leaderIds) { pid, readArguments in
                try Task.checkCancellation()
                return failedMemberReads[pid] ?? kernelReader.readNativeSample(pid: pid, readArguments: readArguments)
            }
            try Task.checkCancellation()
            return .init(
                samples: pass.samples, incompleteLeaders: pass.incompleteLeaders.union(incompleteLeaders),
                leadersWithVanishedRows: pass.leadersWithVanishedRows)
        }
    }

    /// A full buffer may be truncated. Retry once with greater capacity, then
    /// report the group unreadable rather than classify a partial membership list.
    package static func readGroupMembers(
        _ groupId: Int32, kernelReader: any TerminalForegroundKernelReading
    ) throws -> [Int32]? {
        let stride = MemoryLayout<Int32>.stride
        var previousCapacity = 0
        for _ in 0..<2 {
            try Task.checkCancellation()
            let estimatedBytes = kernelReader.listProcessGroup(groupId, buffer: nil, bufferSize: 0)
            guard estimatedBytes >= 0, Int(estimatedBytes).isMultiple(of: stride) else { return nil }
            let capacity = max(Int(estimatedBytes), previousCapacity * 2) + stride
            guard let bufferSize = Int32(exactly: capacity) else { return nil }
            var members = [Int32](repeating: 0, count: capacity / stride)
            try Task.checkCancellation()
            let fetchedBytes = members.withUnsafeMutableBytes {
                kernelReader.listProcessGroup(groupId, buffer: $0.baseAddress, bufferSize: bufferSize)
            }
            try Task.checkCancellation()
            guard fetchedBytes >= 0, fetchedBytes <= bufferSize, Int(fetchedBytes).isMultiple(of: stride) else {
                return nil
            }
            if fetchedBytes < bufferSize { return Array(members.prefix(Int(fetchedBytes) / stride)) }
            previousCapacity = capacity
        }
        return nil
    }

    /// Attributes one scoped pass's native read outcomes to only the leaders that own each row.
    package static func attributeSamples(
        rows: [(pid: Int32, group: Int32, foreground: Int32)], requestedLeaderPids leaderIds: Set<Int32>,
        readSample: (Int32, Bool) throws -> NativeSampleReadResult
    ) rethrows -> ForegroundPsPass {
        var foregroundGroupsByLeader: [Int32: Int32] = [:]
        for row in rows where leaderIds.contains(row.pid) && row.foreground > 0 {
            foregroundGroupsByLeader[row.pid] = row.foreground
        }
        let foregroundGroups = Set(foregroundGroupsByLeader.values)
        let selected = rows.filter { leaderIds.contains($0.pid) || foregroundGroups.contains($0.group) }
        var incompleteLeaders = leaderIds.subtracting(rows.map(\.pid))
        var leadersWithVanishedRows: Set<Int32> = []
        var samples: [ForegroundProcessSample] = []
        for row in selected {
            let affectedLeaders = leaderIds.filter {
                $0 == row.pid || foregroundGroupsByLeader[$0] == row.group
            }
            switch try readSample(row.pid, foregroundGroups.contains(row.group)) {
            case .sample(let sample):
                // A group change invalidates only the leaders that own this row.
                guard sample.processGroupId == row.group, sample.foregroundGroupId == row.foreground else {
                    incompleteLeaders.formUnion(affectedLeaders)
                    continue
                }
                samples.append(sample)
            case .vanished:
                leadersWithVanishedRows.formUnion(affectedLeaders)
                if leaderIds.contains(row.pid) { incompleteLeaders.insert(row.pid) }
            case .unreadable:
                incompleteLeaders.formUnion(affectedLeaders)
            }
        }
        return .init(
            samples: samples, incompleteLeaders: incompleteLeaders,
            leadersWithVanishedRows: leadersWithVanishedRows)
    }

    package enum NativeSampleReadResult: Sendable {
        case sample(ForegroundProcessSample)
        case vanished
        case unreadable
    }

}

private struct ForegroundZmxSessionControl: ZmxSessionControlling {
    let directory: String
    let bootId: String

    @concurrent nonisolated func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
        let path = "\(directory)/\(sessionID.rawValue)"
        if try ZmxSessionControl.endpointIsAbsent(path: path) { return nil }
        do { return try ZmxSessionControl.observe(path: path, bootID: bootId).encoded() } catch {
            if try ZmxSessionControl.endpointIsAbsent(path: path) { return nil }
            throw error
        }
    }

    func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) async throws
        -> ZmxSessionCleanupStatus
    {
        // The observer is inspection-only; retirement remains the existing runtime owner's job.
        throw ZmxSessionControlFailure.unavailable
    }
}
