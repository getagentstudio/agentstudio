import Foundation
import Synchronization

@testable import AgentStudioCore

struct ChainReadKey: Hashable, Sendable {
    let pid: Int32
    let ordinal: Int
}

enum ChainReadResult: Sendable {
    case available(ProcessChainProcessFacts)
    case unavailable
}

final class ScriptedChainFacts: ProcessChainFactsReading {
    private struct State {
        var versions: [UInt32?]
        var versionIndex = 0
        var readsByPID: [Int32: Int] = [:]
        var totalReads = 0
    }
    private let table: [Int32: ProcessChainProcessFacts]
    private let overrides: [ChainReadKey: ChainReadResult]
    private let state: Mutex<State>

    init(
        table: [Int32: ProcessChainProcessFacts], versions: [UInt32?] = [17, 17],
        overrides: [ChainReadKey: ChainReadResult] = [:]
    ) {
        self.table = table
        self.overrides = overrides
        state = Mutex(State(versions: versions))
    }

    var totalReads: Int { state.withLock { $0.totalReads } }

    func pidVersion(of pid: Int32) -> UInt32? {
        state.withLock {
            $0.totalReads += 1
            let version = $0.versions[min($0.versionIndex, $0.versions.count - 1)]
            $0.versionIndex += 1
            return version
        }
    }

    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? {
        state.withLock {
            $0.totalReads += 1
            $0.readsByPID[pid, default: 0] += 1
            let key = ChainReadKey(pid: pid, ordinal: $0.readsByPID[pid, default: 0])
            switch overrides[key] {
            case .available(let facts): return facts
            case .unavailable: return nil
            case nil: return table[pid]
            }
        }
    }
}

func chainIncarnation(_ pid: Int32, started: UInt64? = nil) -> ZmxProcessIncarnation {
    .init(pid: pid, startSeconds: started ?? UInt64(pid), startMicroseconds: 0)
}

func chainFact(_ pid: Int32, parent: Int32, name: String, started: UInt64? = nil) -> ProcessChainProcessFacts {
    .init(incarnation: chainIncarnation(pid, started: started), parentPID: parent, executableName: name)
}
