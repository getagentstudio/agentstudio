import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context membership directory")
struct PaneContextMembershipDirectoryTests {
    @Test("Owner lookup returns only a validated drawer parent", arguments: ["drawer", "ordinary", "absent"])
    func ownerLookupTable(kind: String) throws {
        let fixture = MembershipInstallationFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(fixture.first)
        try #require(directory.view(for: fixture.owner) != nil)
        let paneId = kind == "drawer" ? fixture.firstChild : kind == "ordinary" ? fixture.owner : .generateUUIDv7()
        #expect(directory.ownerPaneId(for: paneId) == (kind == "drawer" ? fixture.owner : nil))
    }

    @Test("Workspace identity, presence and source order are read from one installed version")
    func installedVersionCarriesIdentityAndSources() throws {
        let fixture = MembershipInstallationFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(fixture.first)
        let view = try #require(directory.view(for: fixture.owner), "Inert directory must fail before any wait")
        #expect(view.workspaceId == fixture.first.workspaceId)
        #expect(view.membershipRevision == fixture.first.membershipRevision)
        #expect(view.sources == [fixture.owner, fixture.firstChild])
        #expect(directory.contains(paneID: fixture.owner.uuid, inWorkspace: fixture.first.workspaceId))
        #expect(!directory.contains(paneID: fixture.owner.uuid, inWorkspace: fixture.second.workspaceId))
        #expect(directory.sources(for: fixture.firstChild) == [fixture.firstChild])
        #expect(directory.ownerPaneId(for: fixture.firstChild) == fixture.owner)
        #expect(directory.ownerPaneId(for: fixture.owner) == nil)
        #expect(directory.ownerPaneId(for: .generateUUIDv7()) == nil)
        #expect(Set(directory.currentOwners().map(\.paneId)) == [fixture.owner, fixture.firstChild])
    }

    @Test("A child's parent and the owner's child list must agree in the same version")
    func mismatchedChildCannotBecomeAReadSource() {
        let owner = PaneId.generateUUIDv7()
        let child = PaneId.generateUUIDv7()
        let otherParent = PaneId.generateUUIDv7()
        let directory = PaneContextMembershipDirectory()
        directory.install(
            .init(
                workspaceId: UUIDv7.generate(), membershipRevision: 1,
                entries: [
                    .init(paneId: owner, placement: .layout, ownedDrawerChildIds: [child]),
                    .init(
                        paneId: child, placement: .drawerChild(parentPaneID: otherParent.uuid), ownedDrawerChildIds: []),
                    .init(paneId: otherParent, placement: .layout, ownedDrawerChildIds: []),
                ]))
        #expect(directory.sources(for: owner) == [owner])
        #expect(directory.sources(for: child) == [child])
        #expect(directory.ownerPaneId(for: child) == nil)
    }

    @Test("Whole install replaces identity and membership without retaining old child ids")
    func installReplacesWholeVersion() throws {
        let fixture = MembershipInstallationFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(fixture.first)
        try #require(directory.view(for: fixture.owner) != nil)
        directory.install(fixture.second)
        let view = try #require(directory.view(for: fixture.owner))
        #expect(view.workspaceId == fixture.second.workspaceId)
        #expect(view.membershipRevision == fixture.second.membershipRevision)
        #expect(view.sources == [fixture.owner, fixture.secondChild])
        #expect(!directory.contains(paneID: fixture.firstChild.uuid, inWorkspace: fixture.second.workspaceId))
    }

    @Test("Subscription before snapshot retains a wake for the next committed version")
    func subscribedReaderCannotLoseMembershipChange() async throws {
        let fixture = MembershipInstallationFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(fixture.first)
        let wakes = directory.wakes
        let snapshot = try #require(directory.view(for: fixture.owner), "RED must fail before awaiting a wake")
        _ = directory.takeAffectedOwners()
        directory.commit(changed: fixture.second.entries, removed: [fixture.firstChild])
        directory.commit(changed: fixture.first.entries, removed: [fixture.secondChild])
        let current = try #require(directory.view(for: fixture.owner))
        try #require(current.membershipRevision > snapshot.membershipRevision)
        let source = LocalFactSource<UInt64, PendingAffectedOwners>(
            vocabulary: .init(
                describeScope: { "membership version \($0)" }, describeFact: { "affected owners \($0)" },
                isClosing: { _, _ in true }))
        let facts = try source.attach()
        let consumer = Task {
            for await _ in wakes {
                source.sink(current.membershipRevision, directory.takeAffectedOwners())
                source.end()
                return
            }
            source.end()
        }
        do {
            try await facts.expectNext(
                in: current.membershipRevision,
                .owners([fixture.owner, fixture.firstChild, fixture.secondChild]))
            await consumer.value
            try await facts.finish()
        } catch {
            consumer.cancel()
            await consumer.value
            try? await facts.finish()
            throw error
        }
        #expect(directory.takeAffectedOwners() == .owners([]))
        #expect(current.sources == [fixture.owner, fixture.firstChild])
    }

    @Test("Concurrent installs are observed only as complete compact versions")
    func concurrentInstallNeverExposesMixedVersion() async throws {
        let fixture = MembershipInstallationFixture()
        let directory = PaneContextMembershipDirectory()
        directory.install(fixture.first)
        try #require(directory.view(for: fixture.owner) != nil, "No tasks start against the inert directory")
        let values = await withTaskGroup(of: [PaneContextMembershipView?].self) { group in
            group.addTask {
                for _ in 0..<20 {
                    directory.install(fixture.second)
                    directory.install(fixture.first)
                }
                return []
            }
            group.addTask {
                (0..<40).map { _ in directory.view(for: fixture.owner) }
            }
            var observations: [PaneContextMembershipView?] = []
            for await batch in group { observations.append(contentsOf: batch) }
            return observations
        }
        #expect(values.count == 40)
        for value in values {
            let view = try #require(value)
            let expected = view.workspaceId == fixture.first.workspaceId ? fixture.first : fixture.second
            #expect(view.workspaceId == expected.workspaceId)
            #expect(view.membershipRevision == expected.membershipRevision)
            #expect(view.sources == [fixture.owner] + expected.entries[0].ownedDrawerChildIds)
        }
    }
}

private struct MembershipInstallationFixture: Sendable {
    let owner = PaneId.generateUUIDv7()
    let firstChild = PaneId.generateUUIDv7()
    let secondChild = PaneId.generateUUIDv7()
    let firstWorkspaceId = UUIDv7.generate()
    let secondWorkspaceId = UUIDv7.generate()

    var first: PaneContextMembershipInstallation {
        installation(workspaceId: firstWorkspaceId, child: firstChild, revision: 1)
    }
    var second: PaneContextMembershipInstallation {
        installation(workspaceId: secondWorkspaceId, child: secondChild, revision: 2)
    }

    private func installation(workspaceId: UUID, child: PaneId, revision: UInt64) -> PaneContextMembershipInstallation {
        .init(
            workspaceId: workspaceId, membershipRevision: revision,
            entries: [
                .init(paneId: owner, placement: .layout, ownedDrawerChildIds: [child]),
                .init(paneId: child, placement: .drawerChild(parentPaneID: owner.uuid), ownedDrawerChildIds: []),
            ])
    }
}
