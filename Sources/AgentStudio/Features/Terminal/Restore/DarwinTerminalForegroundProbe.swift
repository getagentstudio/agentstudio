import AgentStudioCore
import AgentStudioInfrastructure
import Darwin
import Foundation

/// Ephemeral ps input. argv0 must never enter the durable observation row.
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
    private let readSamples: (@Sendable () async throws -> ForegroundPsPass)?
    package init(
        sessionDirectory: String, bootId: String,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        sessionControl: (any ZmxSessionControlling)? = nil,
        readSamples: (@Sendable () async throws -> ForegroundPsPass)? = nil
    ) {
        self.performanceTraceRecorder = performanceTraceRecorder
        self.sessionControl = sessionControl ?? ForegroundZmxSessionControl(directory: sessionDirectory, bootId: bootId)
        self.readSamples = readSamples
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
                performanceTraceRecorder: performanceTraceRecorder)
        }
        var snapshots: [ZmxSessionID: ForegroundSnapshot] = [:]
        for (sessionId, captured) in identities {
            let (data, identity) = captured
            // The socket may have disappeared or been replaced during ps.
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

    /// Only metadata comes from ps. argv is read solely for the requested
    /// terminal leaders' foreground groups and discarded with this pass.
    @concurrent nonisolated private static func readNativeSamples(
        leaders: [ProcessIncarnation], performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    ) async throws -> ForegroundPsPass {
        let leaderIds = Set(leaders.map(\.pid))
        let result: ProcessResult
        do {
            result = try await AgentStudioPerformanceTraceRecorder.withRestorePhaseScope(.restoreForegroundProbe) {
                try await DefaultProcessExecutor(performanceTraceRecorder: performanceTraceRecorder).execute(
                    command: "/bin/ps", args: ["-axo", "pid=,pgid=,tpgid="], cwd: nil, environment: nil)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            return .init(samples: [], incompleteLeaders: leaderIds, leadersWithVanishedRows: [])
        }
        return try AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreForegroundProbe, recorder: performanceTraceRecorder
        ) {
            guard result.succeeded else {
                return .init(samples: [], incompleteLeaders: leaderIds, leadersWithVanishedRows: [])
            }
            let lines = result.stdout.split(separator: "\n")
            let rows = lines.compactMap { line -> (pid: Int32, group: Int32, foreground: Int32)? in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count == 3, let pid = Int32(fields[0]), let group = Int32(fields[1]),
                    let foreground = Int32(fields[2])
                else { return nil }
                return (pid, group, foreground)
            }
            guard rows.count == lines.count else {
                return .init(samples: [], incompleteLeaders: leaderIds, leadersWithVanishedRows: [])
            }
            return try attributeSamples(rows: rows, requestedLeaderPids: leaderIds) { pid, readArguments in
                try Task.checkCancellation()
                return readNativeSample(pid: pid, readArguments: readArguments)
            }
        }
    }

    /// Attributes one parsed pass's native read outcomes to only the leaders that own each row.
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

    private static func readNativeSample(pid: Int32, readArguments: Bool) -> NativeSampleReadResult {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size else {
            return errno == ESRCH ? .vanished : .unreadable
        }
        guard information.pbi_uid == geteuid(), information.pbi_pid == UInt32(pid) else { return .unreadable }
        let incarnation = ProcessIncarnation(
            pid: pid, startSeconds: information.pbi_start_tvsec, startMicroseconds: information.pbi_start_tvusec)
        var argv0 = ""
        if readArguments {
            guard case .success(let buffer) = DarwinColdStartObserverSyscalls().readProcessArgumentsBuffer(pid: pid),
                let argument = ProcessArgumentsBufferParser.argumentVector(in: buffer)?.first,
                DarwinColdStartObserverSyscalls().leaderState(of: incarnation) == .sameIncarnationAlive
            else { return .unreadable }
            argv0 = argument
        }
        return .sample(
            ForegroundProcessSample(
                incarnation: incarnation, processGroupId: Int32(information.pbi_pgid),
                foregroundGroupId: Int32(information.e_tpgid), argv0: argv0))
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
