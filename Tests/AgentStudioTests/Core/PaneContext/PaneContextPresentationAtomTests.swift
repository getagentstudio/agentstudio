import Foundation
import Observation
import Synchronization
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context presentation atom", .serialized)
struct PaneContextPresentationAtomTests {
    @Test("One assignment batch keeps own and including-drawer counts distinct")
    func keyedValuesKeepBothCountGroups() {
        let atom = PaneContextPresentationAtom()
        let first = PaneId.generateUUIDv7()
        let second = PaneId.generateUUIDv7()
        let own = PaneMessageCounts(
            needsApprovalCount: 1, needsReplyCount: 2, attentionCount: 3, informationalCount: 4,
            newestOpenBlockingAskId: .generateUUIDv7())
        let all = PaneMessageCounts(
            needsApprovalCount: 5, needsReplyCount: 6, attentionCount: 7, informationalCount: 8,
            newestOpenBlockingAskId: .generateUUIDv7())
        let display = presentationDisplay(own: own, includingDrawers: all)
        atom.apply([first: .set(display), second: .set(presentationDisplay(title: "Other"))])
        #expect(atom.value(for: first)?.own == own)
        #expect(atom.value(for: first)?.includingDrawers == all)
        #expect(atom.value(for: second)?.agentTitle == "Other")
        atom.apply([first: .remove])
        #expect(atom.value(for: first) == nil)
        #expect(atom.value(for: second)?.agentTitle == "Other")
        atom.remove([second])
        #expect(atom.value(for: second) == nil)
    }

    @Test("Equal or unrelated assignments do not wake a keyed observer")
    func comparatorIsAnObservationBackstop() throws {
        let atom = PaneContextPresentationAtom()
        let watched = PaneId.generateUUIDv7()
        let other = PaneId.generateUUIDv7()
        let display = presentationDisplay(title: "Watched")
        atom.apply([watched: .set(display)])
        try #require(atom.value(for: watched) == display)
        let changed = Mutex(false)
        withObservationTracking {
            _ = atom.value(for: watched)
        } onChange: {
            changed.withLock { $0 = true }
        }
        atom.apply([watched: .set(display), other: .set(presentationDisplay(title: "Other"))])
        #expect(!changed.withLock { $0 })
        atom.apply([watched: .set(presentationDisplay(revision: 2, title: "Watched"))])
        #expect(changed.withLock { $0 })
    }

    @Test("Agent title layers above the pane name and reset reveals its current name")
    func titleLayerDoesNotOverwriteFallback() {
        let atom = PaneContextPresentationAtom()
        let derived = PaneDisplayTitleDerived(presentation: atom)
        let pane = PaneId.generateUUIDv7()
        #expect(derived.title(for: pane, fallbackTitle: "OSC name") == "OSC name")
        atom.apply([pane: .set(presentationDisplay(title: "Agent title"))])
        #expect(derived.title(for: pane, fallbackTitle: "Changed OSC name") == "Agent title")
        atom.apply([pane: .set(presentationDisplay(revision: 2, title: nil))])
        #expect(derived.title(for: pane, fallbackTitle: "Changed OSC name") == "Changed OSC name")
        atom.apply([pane: .set(presentationDisplay(revision: 3, title: ""))])
        #expect(derived.title(for: pane, fallbackTitle: "Fallback").isEmpty)
    }

    @Test("A stale Agent Line remains visible as the already-decided value")
    func staleLineIsAssignedWithoutBusinessRules() {
        let atom = PaneContextPresentationAtom()
        let pane = PaneId.generateUUIDv7()
        let line = AgentLineDetail(
            summary: "Watching", work: .monitoring("checks"), detail: nil, refs: [], writer: .pane(pane),
            updatedAt: Date(timeIntervalSince1970: 100), lifetime: .untilReplaced, stale: true)
        atom.apply([pane: .set(presentationDisplay(line: line))])
        #expect(atom.value(for: pane)?.agentLine == line)
    }
}
