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
        atom.apply([first: .set(.init(status: .working(.active))), second: .set(.init(status: .idle(.ended)))])
        #expect(atom.value(for: first)?.status == .working(.active))
        #expect(atom.value(for: second)?.status == .idle(.ended))
        atom.apply([first: .set(.init(status: .needsYou(.question)))])
        #expect(atom.value(for: second)?.status == .idle(.ended))
        atom.apply([first: .remove])
        #expect(atom.value(for: first) == nil)
        #expect(atom.value(for: second)?.status == .idle(.ended))
    }
    @Test("the atom assigns status and connection issue as one cohesive value")
    func cohesiveStatusPresentation() {
        let atom = SessionStatusAtom()
        let pane = PaneId.generateUUIDv7()
        let presentation = PaneAgentStatusPresentation(
            status: .needsYou(.approval), connectionIssue: .credentialNotRecognized)
        atom.apply([pane: .set(presentation)])
        #expect(atom.value(for: pane) == presentation)
        atom.apply([pane: .set(.init(status: .working(.active)))])
        #expect(atom.value(for: pane)?.connectionIssue == nil)
    }

}
