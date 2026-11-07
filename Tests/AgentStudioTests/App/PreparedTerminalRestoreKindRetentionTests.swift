import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Prepared terminal classification retention", .serialized)
struct PreparedTerminalRestoreKindRetentionTests {
    @Test("streamed kinds retain earlier incompatible panes until their claims are minted")
    func streamedKindsRetainEveryPane() async throws {
        let generation = WorkspaceContentMountGeneration()
        let panes = [makePreparedTerminalTestPane(), makePreparedTerminalTestPane()]
        let descriptors = panes.map {
            TerminalActivationDescriptor(
                pane: $0, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate()))
        }
        let registry = ViewRegistry()
        registry.installPreparedContentMountCohort(
            .init(
                generation: generation, terminalActivationInput: .init(entries: descriptors),
                nonterminalContentMountInput: .init(entries: [])))
        let port = PreparedTerminalMountAdmissionPort(
            generation: generation,
            initialFramesByPaneID: Dictionary(
                uniqueKeysWithValues: descriptors.map { ($0.paneID, NSRect(x: 0, y: 0, width: 800, height: 600)) }),
            viewRegistry: registry, mountHandler: RecordingPreparedTerminalMountHandler(results: []),
            descriptorsByPaneID: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) }))
        let plan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: panes[0], sessionID: try #require(panes[0].terminalState?.zmxSessionID),
            launchPaths: .init(
                zmxExecutablePath: "/usr/bin/true", zmxDirectoryPath: "/tmp/no-daemon", loginShellPath: "/bin/sh"),
            repositoryMainFolder: nil,
            scrollbackStore: ScrollbackStore(directoryURL: URL(filePath: "/tmp/no-saved-output")))
        let kinds: [TerminalRestoreKind] = [
            .incompatible(0, fallback: plan), .warm(identity: Data("current".utf8), fallback: plan),
        ]

        // This is the production streaming contract: separate deltas, both before activation is released.
        for (descriptor, kind) in zip(descriptors, kinds) {
            port.installRestoreKinds([descriptor.paneID: kind])
        }

        for (descriptor, expectedKind) in zip(descriptors, kinds) {
            let outcome = port.claimPreparedTerminal(
                .init(
                    generation: generation, paneID: descriptor.paneID, attempt: 1,
                    appliedVisibilityRevision: .init(generation: generation, ordinal: 0)))
            guard case .claimed(let claim) = outcome else {
                Issue.record("Every prepared pane must receive a classified claim")
                return
            }
            #expect(claim.admission.restoreKind == expectedKind)
        }
    }
}
