import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership lifetime", .serialized)
struct PaneContextMembershipLifetimeTests {
    @Test("Canonical close removes the key; Undo republishes the same pane id and its retained counts")
    func closeAndUndoRestoreCurrentMembership() async throws {
        try await withPaneContextMembershipLifetime { fixture in
            let initial = try await fixture.display()
            try await fixture.expectApplied(.set(initial))
            try await fixture.storage.sendCreated(fixture.storage.ask(), to: fixture.service)
            let before = try await fixture.display()
            try await fixture.expectApplied(.set(before))
            try #require(fixture.graph.graph.deletePaneAndOwnedDrawerChildren(fixture.graph.seed.id))
            await fixture.service.reconcileMembership()
            try await fixture.expectApplied(.remove)
            #expect(fixture.atom.value(for: fixture.storage.paneId) == nil)
            try await fixture.withNoPublication {
                #expect(!fixture.mailbox.offer(before, for: fixture.storage.paneId))
            }
            try #require(fixture.graph.graph.insertRestoredPane(fixture.graph.seed))
            await fixture.service.reconcileMembership()
            let after = try await fixture.display()
            #expect(after.own == before.own)
            #expect(after.own.needsReplyCount == 1)
            #expect(after.revision.value > before.revision.value)
            try await fixture.expectApplied(.set(after))
            #expect(fixture.atom.value(for: fixture.storage.paneId) == after)
        }
    }

    @Test("Permanent Undo expiry keeps a removed key fenced even if stale topology later restores its id")
    func permanentRetirementCannotBeUndone() async throws {
        try await withPaneContextMembershipLifetime { fixture in
            let before = try await fixture.display()
            try await fixture.expectApplied(.set(before))
            try #require(fixture.graph.graph.deletePaneAndOwnedDrawerChildren(fixture.graph.seed.id))
            await fixture.service.reconcileMembership()
            try await fixture.expectApplied(.remove)
            fixture.service.retire([fixture.storage.paneId])
            #expect(await fixture.service.readDetail(.init(paneId: fixture.storage.paneId, page: .first)) == .paneGone)
            try await fixture.expectApplied(.remove)
            try await fixture.withNoPublication {
                try #require(fixture.graph.graph.insertRestoredPane(fixture.graph.seed))
                await fixture.service.reconcileMembership()
                #expect(fixture.atom.value(for: fixture.storage.paneId) == nil)
                #expect(!fixture.mailbox.offer(before, for: fixture.storage.paneId))
                #expect(await fixture.service.readDisplay(paneId: fixture.storage.paneId) == nil)
            }
        }
    }

    @Test("Close without Undo refuses an ordinary offer using current canonical presence")
    func currentAbsenceRefusesLateOffer() async throws {
        try await withPaneContextMembershipLifetime { fixture in
            let before = try await fixture.display()
            try await fixture.expectApplied(.set(before))
            try #require(fixture.graph.graph.deletePaneAndOwnedDrawerChildren(fixture.graph.seed.id))
            await fixture.service.reconcileMembership()
            try await fixture.expectApplied(.remove)
            try await fixture.withNoPublication {
                #expect(!fixture.mailbox.offer(before, for: fixture.storage.paneId))
                #expect(fixture.atom.value(for: fixture.storage.paneId) == nil)
                #expect(await fixture.service.readDisplay(paneId: fixture.storage.paneId) == nil)
            }
        }
    }
}
