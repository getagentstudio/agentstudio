import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Shared chip caller review frames", .serialized)
struct SidebarChipConsumerFramesTests {
    enum LegacyChipConsumer: String, CaseIterable {
        case sidebarGit, workspaceStatus, identityStrip, navigationActivity

        var width: CGFloat {
            switch self {
            case .sidebarGit, .navigationActivity: 260
            case .workspaceStatus: 320
            case .identityStrip: 520
            }
        }
    }

    @Test(
        "Shared chip callers retain their main paint outside popovers",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: LegacyChipConsumer.allCases)
    func renderLegacyChipConsumers(consumer: LegacyChipConsumer) throws {
        installTestCoreAtomsIfNeeded()
        let mounted = PaneIdentityCardFixture.mountView(try legacyChipContent(consumer), width: consumer.width)
        defer {
            mounted.window.contentView = nil
            mounted.window.close()
        }
        try recordPaneLineDiagnosticFrame(mounted.host, name: "consumer-" + consumer.rawValue)
        #expect(mounted.host.bounds.width == consumer.width)
        #expect(mounted.host.bounds.height > 0)
    }

    private func legacyChipContent(_ consumer: LegacyChipConsumer) throws -> AnyView {
        let loader = makeTestOcticonLoader()
        let branch = GitBranchStatus(
            isDirty: true, syncState: .diverged(ahead: 2, behind: 1), prCount: 3,
            linesAdded: 4, linesDeleted: 2, untrackedFileCount: 1)
        switch consumer {
        case .sidebarGit:
            return AnyView(SidebarGitStatusChips(branchStatus: branch, octiconLoader: loader))
        case .workspaceStatus:
            return AnyView(
                WorkspaceStatusChipRow(
                    octiconLoader: loader, model: .init(branchStatus: branch),
                    accentColor: AppStyles.General.Accent.primaryColor))
        case .identityStrip:
            return AnyView(try PaneIdentityCardFixture.strip("secondary-lines"))
        case .navigationActivity:
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    RepoExplorerPaneRowContent(
                        variant: .init(
                            lines: [.title("Navigation pane")],
                            activityChip: .init(text: "2 min ago", nextChange: .distantFuture)),
                        isDrawerPane: false, octiconLoader: loader)
                    HStack(spacing: 4) {
                        RepoExplorerPaneActivityChips(
                            recencyText: "2 min ago", recencyTier: .strongBlue, isActive: true, octiconLoader: loader)
                    }
                })
        }
    }
}
