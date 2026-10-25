import Foundation
import Synchronization

@testable import AgentStudioTerminal

final class ForegroundCountingKernelReader: TerminalForegroundKernelReading, Sendable {
    struct SampleRead: Equatable, Sendable {
        let pid: Int32
        let readArguments: Bool
    }
    struct GroupRead: Equatable, Sendable {
        let groupId: Int32
        let bufferSize: Int32
    }
    struct State: Sendable {
        var samples: [Int32: [DarwinTerminalForegroundProbe.NativeSampleReadResult]] = [:]
        var groups: [Int32: [[Int32]]] = [:]
        var estimatedBytes: [Int32: Int32] = [:]
        var fetchedBytes: [Int32: Int32] = [:]
        var sampleReads: [SampleRead] = []
        var groupReads: [GroupRead] = []
        var cancellationCall: Int?
        var callCount = 0
    }
    private let state: Mutex<State>

    init(_ initial: State) { state = Mutex(initial) }
    func snapshot() -> State { state.withLock { $0 } }

    func readNativeSample(pid: Int32, readArguments: Bool) -> DarwinTerminalForegroundProbe.NativeSampleReadResult {
        let (result, cancel) = state.withLock { state in
            state.sampleReads.append(.init(pid: pid, readArguments: readArguments))
            state.callCount += 1
            var results = state.samples[pid] ?? [.unreadable]
            let result = results[0]
            if results.count > 1 { results.removeFirst() }
            state.samples[pid] = results
            return (result, state.callCount == state.cancellationCall)
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        guard case .sample(let sample) = result else { return result }
        return .sample(
            ForegroundProcessSample(
                incarnation: sample.incarnation, processGroupId: sample.processGroupId,
                foregroundGroupId: sample.foregroundGroupId, argv0: readArguments ? sample.argv0 : ""))
    }

    func listProcessGroup(_ groupId: Int32, buffer: UnsafeMutableRawPointer?, bufferSize: Int32) -> Int32 {
        let (members, resultBytes, cancel) = state.withLock { state in
            state.groupReads.append(.init(groupId: groupId, bufferSize: bufferSize))
            state.callCount += 1
            var lists = state.groups[groupId] ?? [[]]
            let members = lists[0]
            let resultBytes: Int32
            if buffer == nil {
                resultBytes = state.estimatedBytes[groupId] ?? Int32(members.count * MemoryLayout<Int32>.stride)
            } else {
                resultBytes =
                    state.fetchedBytes[groupId] ?? min(bufferSize, Int32(members.count * MemoryLayout<Int32>.stride))
                if lists.count > 1 { lists.removeFirst() }
                state.groups[groupId] = lists
            }
            return (members, resultBytes, state.callCount == state.cancellationCall)
        }
        if let buffer {
            let capacity = Int(bufferSize) / MemoryLayout<Int32>.stride
            for (index, pid) in members.prefix(capacity).enumerated() {
                buffer.storeBytes(of: pid, toByteOffset: index * MemoryLayout<Int32>.stride, as: Int32.self)
            }
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return resultBytes
    }
}
