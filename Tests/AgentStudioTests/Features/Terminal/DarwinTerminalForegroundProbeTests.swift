import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@Suite("Darwin terminal foreground probe")
struct DarwinTerminalForegroundProbeTests {
    @Test("foreground discovery cannot launch a process or list every PID")
    func discoveryDoesNotLaunchProcesses() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        for filename in ["DarwinTerminalForegroundProbe.swift", "TerminalForegroundKernelReader.swift"] {
            let source = try String(
                contentsOf: root.appending(path: "Sources/AgentStudio/Features/Terminal/Restore/\(filename)"),
                encoding: .utf8)
            for forbidden in ["/bin/ps", "ProcessExecutor", "Process(", "proc_listallpids", "PROC_ALL_PIDS"] {
                #expect(!source.contains(forbidden), "foreground discovery must not use \(forbidden)")
            }
        }
    }

    @Test("requested leaders share one group listing and exclude unrelated processes and argv")
    func requestedLeadersAndForegroundMembersOnly() async throws {
        let firstSession = ZmxSessionID.generateUUIDv7()
        let secondSession = ZmxSessionID.generateUUIDv7()
        let firstIdentity = try foregroundTestIdentity()
        let secondIdentity = try foregroundTestIdentity(leaderPid: 5100)
        var state = kernelState()
        state.samples[5100] = [.sample(sample(5100, group: 5100, foreground: 4200, argv0: "zsh"))]
        state.samples[9999] = [.sample(sample(9999, group: 9999, foreground: 9999, argv0: "codex"))]
        let kernel = ForegroundCountingKernelReader(state)
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        let probe = DarwinTerminalForegroundProbe(
            sessionDirectory: "/unused-kernel-proof", bootId: "foreground-proof-boot",
            performanceTraceRecorder: trace.recorder,
            sessionControl: KernelProbeSessionControl(identities: [
                firstSession: firstIdentity, secondSession: secondIdentity,
            ]), kernelReader: kernel)

        let snapshots = try await probe.probeForeground(of: [firstSession, secondSession, firstSession])
        let reads = kernel.snapshot()
        let traceRows = try await trace.finish()

        #expect(snapshots[firstSession]?.program == .claudeCode)
        #expect(snapshots[secondSession]?.program == .claudeCode)
        #expect(snapshots[firstSession]?.foregroundProcess == foregroundTestProcess(pid: 4200))
        #expect(snapshots[firstSession]?.sessionIdentity == firstIdentity)
        #expect(reads.groupReads.map(\.groupId) == [4200, 4200])
        #expect(Set(reads.sampleReads.map(\.pid)) == [4100, 5100, 4200])
        #expect(reads.sampleReads.count == 6)
        #expect(reads.sampleReads.filter(\.readArguments).map(\.pid) == [4200])
        #expect(traceRows.count == 1)
        #expect(traceRows.first?.body == "performance.restore.foreground.probe")
        #expect(traceRows.first?.attributes.mainThreadExecutions == 0)
    }

    @Test("a leader without a foreground group stays unknown without listing groups", arguments: [Int32(0), -1])
    func leaderWithoutForegroundGroup(foreground: Int32) async throws {
        let kernel = ForegroundCountingKernelReader(
            .init(samples: [
                4100: [.sample(sample(4100, group: 4100, foreground: foreground, argv0: "zsh"))]
            ]))
        let pass = try await probePass(kernel)

        #expect(classify(pass) == .unknown)
        #expect(pass.incompleteLeaders.isEmpty)
        #expect(kernel.snapshot().groupReads.isEmpty)
        #expect(kernel.snapshot().sampleReads.allSatisfy { !$0.readArguments && $0.pid == 4100 })
    }

    @Test("a shell leader in its own foreground group is read once per phase and classifies shell")
    func shellLeaderInForegroundGroup() async throws {
        let kernel = ForegroundCountingKernelReader(
            .init(
                samples: [4100: [.sample(sample(4100, group: 4100, foreground: 4100, argv0: "/bin/zsh"))]],
                groups: [4100: [[4100, 4100]]]))
        let pass = try await probePass(kernel)

        #expect(classify(pass) == .shell)
        #expect(pass.samples.count == 1)
        #expect(
            kernel.snapshot().sampleReads == [
                .init(pid: 4100, readArguments: false), .init(pid: 4100, readArguments: true),
            ])
    }

    @Test("failed or replaced leaders cannot authorize foreground group reads", arguments: [false, true])
    func failedLeaderDoesNotAuthorizeGroup(replaced: Bool) async throws {
        var state = kernelState()
        let replacement = ForegroundProcessSample(
            incarnation: .init(pid: 4100, startSeconds: 101, startMicroseconds: 4100),
            processGroupId: 4100, foregroundGroupId: 4200, argv0: "zsh")
        state.samples[4100] = [replaced ? .sample(replacement) : .unreadable]
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(classify(pass) == .unknown)
        #expect(pass.incompleteLeaders == [4100])
        #expect(kernel.snapshot().groupReads.isEmpty)
        #expect(kernel.snapshot().sampleReads.count == 1)
    }

    @Test(
        "vanished members retain per-leader attribution and readable agents still win",
        arguments: [false, true], [false, true])
    func vanishedMemberRetainsAttribution(agentRemains: Bool, vanishedOnReread: Bool) async throws {
        var state = kernelState()
        state.groups[4200] = [[4200, 4201]]
        state.samples[4201] =
            vanishedOnReread
            ? [.sample(sample(4201, group: 4200, foreground: 4200, argv0: "zsh")), .vanished] : [.vanished]
        if !agentRemains {
            state.samples[4200] = [.sample(sample(4200, group: 4200, foreground: 4200, argv0: "zsh"))]
        }
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(pass.leadersWithVanishedRows == [4100])
        #expect(pass.incompleteLeaders.isEmpty)
        #expect(classify(pass) == (agentRemains ? .claudeCode : .unknown))
    }

    @Test("an unreadable member affects only its owning leader")
    func unreadableMemberPreservesNeighbour() async throws {
        var state = twoLeaderState()
        state.samples[4200] = [.unreadable]
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel, leaders: [4100, 5100])

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(classify(pass, leaderPid: 5100) == .codex)
    }

    @Test("leader foreground and member group changes invalidate only their pane", arguments: [0, 1, 2])
    func groupChangesAreRechecked(change: Int) async throws {
        var state = twoLeaderState()
        switch change {
        case 0:
            state.samples[4100]?.append(.sample(sample(4100, group: 4100, foreground: 4300, argv0: "zsh")))
        case 1:
            state.samples[4200]?.append(.sample(sample(4200, group: 4300, foreground: 4200, argv0: "claude")))
        default:
            state.samples[4200]?.append(.sample(sample(4200, group: 4200, foreground: 4300, argv0: "claude")))
        }
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel, leaders: [4100, 5100])

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(classify(pass, leaderPid: 5100) == .codex)
    }

    @Test("a member regrouped before its first metadata read makes its former group incomplete")
    func groupChangesDuringEnumeration() async throws {
        var state = kernelState()
        state.samples[4200] = [.sample(sample(4200, group: 4300, foreground: 4200, argv0: "claude"))]
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(kernel.snapshot().sampleReads.allSatisfy { !$0.readArguments })
    }

    @Test("growth between list size and fetch is retried in bytes with spare capacity")
    func growingGroupRetriesBeforeClassifying() async throws {
        var state = kernelState()
        state.estimatedBytes[4200] = 4
        state.groups[4200] = [[4200, 4201], [4200, 4201, 4202]]
        for pid in [Int32(4201), 4202] {
            state.samples[pid] = [.sample(sample(pid, group: 4200, foreground: 4200, argv0: "zsh"))]
        }
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(classify(pass) == .claudeCode)
        #expect(pass.incompleteLeaders.isEmpty)
        #expect(Set(pass.samples.map(\.incarnation.pid)) == [4100, 4200, 4201, 4202])
        #expect(kernel.snapshot().groupReads.map(\.bufferSize) == [0, 8, 0, 20])
    }

    @Test("a group that keeps filling the buffer stops after one retry and stays incomplete")
    func continuousGrowthIsBounded() async throws {
        var state = kernelState()
        state.estimatedBytes[4200] = 4
        state.groups[4200] = [Array(4200...4240)]
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(kernel.snapshot().groupReads.map(\.bufferSize) == [0, 8, 0, 20])
        #expect(kernel.snapshot().sampleReads.allSatisfy { $0.pid == 4100 && !$0.readArguments })
    }

    @Test("bad kernel list byte counts affect only the requested group", arguments: [Int32(-1), 3, 100])
    func invalidListResultsAreIncomplete(fetchedBytes: Int32) async throws {
        var state = twoLeaderState()
        state.fetchedBytes[4200] = fetchedBytes
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel, leaders: [4100, 5100])

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(classify(pass, leaderPid: 5100) == .codex)
    }

    @Test("a failed or malformed list size never triggers a fetch", arguments: [Int32(-1), 3, Int32.max - 3])
    func invalidListSizesAreIncomplete(estimatedBytes: Int32) async throws {
        var state = kernelState()
        state.estimatedBytes[4200] = estimatedBytes
        let kernel = ForegroundCountingKernelReader(state)
        let pass = try await probePass(kernel)

        #expect(pass.incompleteLeaders == [4100])
        #expect(classify(pass) == .unknown)
        #expect(kernel.snapshot().groupReads.map(\.bufferSize) == [0])
    }

    @Test("cancellation at every kernel call boundary propagates without further reads", arguments: 0...6)
    func cancellationStopsKernelReads(call: Int) async throws {
        var state = kernelState()
        state.cancellationCall = call
        let kernel = ForegroundCountingKernelReader(state)
        let task = Task {
            if call == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            return try await probePass(kernel)
        }
        do {
            _ = try await task.value
            Issue.record("cancelled native discovery must throw CancellationError")
        } catch is CancellationError {}

        #expect(kernel.snapshot().callCount == call)
    }

    @Test("the production adapter reads this process and lists only its process group")
    func nativeAdapterReadsCurrentProcess() throws {
        let kernel = DarwinTerminalForegroundKernelReader()
        guard case .sample(let current) = kernel.readNativeSample(pid: getpid(), readArguments: false) else {
            Issue.record("current process BSD metadata must be readable")
            return
        }
        let groupMembers = try #require(
            try DarwinTerminalForegroundProbe.readGroupMembers(getpgrp(), kernelReader: kernel))

        #expect(current.incarnation.pid == getpid())
        #expect(current.processGroupId == getpgrp())
        #expect(current.incarnation.startSeconds > 0)
        #expect(current.argv0.isEmpty)
        #expect(groupMembers.contains(getpid()))
    }

    @Test("the production adapter distinguishes a kernel list error from an empty group")
    func nativeAdapterPreservesListFailure() {
        let kernel = DarwinTerminalForegroundKernelReader()
        var memberPid: Int32 = 0
        let result = withUnsafeMutablePointer(to: &memberPid) { buffer in
            // The kernel rejects a non-null list buffer smaller than one PID.
            kernel.listProcessGroup(getpgrp(), buffer: buffer, bufferSize: 1)
        }

        #expect(result == -1)
    }

    private func probePass(_ kernel: ForegroundCountingKernelReader, leaders: [Int32] = [4100]) async throws
        -> ForegroundPsPass
    {
        try await DarwinTerminalForegroundProbe.readNativeSamples(
            leaders: leaders.map { foregroundTestProcess(pid: $0) }, kernelReader: kernel)
    }

    private func classify(_ pass: ForegroundPsPass, leaderPid: Int32 = 4100) -> ForegroundProgram {
        DarwinTerminalForegroundProbe.classify(
            leader: foregroundTestProcess(pid: leaderPid), samples: pass.samples,
            incompleteLeaders: pass.incompleteLeaders, leadersWithVanishedRows: pass.leadersWithVanishedRows)
    }

    private func sample(_ pid: Int32, group: Int32, foreground: Int32, argv0: String) -> ForegroundProcessSample {
        foregroundTestSample(
            process: foregroundTestProcess(pid: pid), group: group, foregroundGroup: foreground, argv0: argv0)
    }

    private func kernelState() -> ForegroundCountingKernelReader.State {
        .init(
            samples: [
                4100: [.sample(sample(4100, group: 4100, foreground: 4200, argv0: "zsh"))],
                4200: [.sample(sample(4200, group: 4200, foreground: 4200, argv0: "claude"))],
            ], groups: [4200: [[4200]]])
    }

    private func twoLeaderState() -> ForegroundCountingKernelReader.State {
        var state = kernelState()
        state.samples[5100] = [.sample(sample(5100, group: 5100, foreground: 5200, argv0: "zsh"))]
        state.samples[5200] = [.sample(sample(5200, group: 5200, foreground: 5200, argv0: "codex"))]
        state.groups[5200] = [[5200]]
        return state
    }
}

private struct KernelProbeSessionControl: ZmxSessionControlling {
    let identities: [ZmxSessionID: Data]
    func observeSessionIdentity(_ sessionID: ZmxSessionID) -> Data? { identities[sessionID] }
    func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) throws -> ZmxSessionCleanupStatus {
        throw ZmxSessionControlFailure.unavailable
    }
}
