import AgentStudioCore
import Testing

@testable import AgentStudioSessions

@MainActor
@Suite("Session status atom", .serialized)
struct SessionStatusAtomTests {
    @Test("one assign-only batch publishes distinct keyed pane values and removal")
    func batchAssignsKeyedValues() {
        let atom = SessionStatusAtom()
        let first = PaneId.generateUUIDv7()
        let second = PaneId.generateUUIDv7()
        atom.apply([first: .set(.working(.active)), second: .set(.idle(.ended))])
        #expect(atom.value(for: first) == .working(.active))
        #expect(atom.value(for: second) == .idle(.ended))
        atom.apply([first: .set(.needsYou(.question))])
        #expect(atom.value(for: second) == .idle(.ended))
        atom.apply([first: .remove])
        #expect(atom.value(for: first) == nil)
        #expect(atom.value(for: second) == .idle(.ended))
    }
}
