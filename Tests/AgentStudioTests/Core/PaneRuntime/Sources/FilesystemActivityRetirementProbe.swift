import Foundation
import Synchronization

@testable import AgentStudioCore

final class FilesystemActivityRetirementProbe: Sendable {
    enum Fact: Equatable, Sendable { case commitReturned, streamRetired }
    private let recorded = Mutex<[Fact]>([])
    var facts: [Fact] { recorded.withLock { $0 } }
    func commitReturned() { recorded.withLock { $0.append(.commitReturned) } }
    func streamRetired() { recorded.withLock { $0.append(.streamRetired) } }
}

final class ActivityRetirementObservedLifetime: DarwinLocalFSEventStreamLifetime, Sendable {
    let probe: FilesystemActivityRetirementProbe
    init(probe: FilesystemActivityRetirementProbe) { self.probe = probe }
    func flush() -> Bool { true }
    func retire() { probe.streamRetired() }
    func scheduleRetirement() { probe.streamRetired() }
}
