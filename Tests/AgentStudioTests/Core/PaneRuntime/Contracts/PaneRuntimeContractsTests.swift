import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("PaneRuntime contracts")
struct PaneRuntimeContractsTests {
    @Test("terminal events expose action policy")
    func terminalPolicy() {
        let event = PaneRuntimeEvent.terminal(.bellRang)
        #expect(event.actionPolicy == .critical)
    }

    @Test("workspace action command does not own terminal runtime shortcuts")
    func workspaceActionCommandDoesNotOwnTerminalRuntimeShortcuts() throws {
        let source = try Self.projectSource(
            "Sources/AgentStudio/Core/Actions/WorkspaceActionCommand.swift"
        )

        #expect(!source.contains("case scrollToBottom"))
        #expect(!source.contains("case scrollPageUp"))
        #expect(!source.contains("case scrollPageDown"))
        #expect(!source.contains("case scrollSmallStepUp"))
        #expect(!source.contains("case scrollSmallStepDown"))
        #expect(!source.contains("case scrollPageFractional"))
        #expect(!source.contains("case jumpToPrompt"))
    }

    @Test("workspace action resolver does not resolve terminal runtime shortcuts")
    func workspaceActionResolverDoesNotResolveTerminalRuntimeShortcuts() throws {
        let source = try Self.projectSource(
            "Sources/AgentStudio/Core/Actions/ActionResolver.swift"
        )

        #expect(!source.contains("return .scrollToBottom"))
        #expect(!source.contains("return .scrollPageUp"))
        #expect(!source.contains("return .scrollPageDown"))
        #expect(!source.contains("return .scrollSmallStepUp"))
        #expect(!source.contains("return .scrollSmallStepDown"))
        #expect(!source.contains("return .scrollPageFractional"))
        #expect(!source.contains("return .jumpToPrompt"))
    }

    @Test("pane runtime contract does not own terminal snapshot facts")
    func paneRuntimeContractDoesNotOwnTerminalSnapshotFacts() throws {
        let source = try Self.projectSource(
            "Sources/AgentStudio/Core/RuntimeEventSystem/Contracts/PaneRuntime.swift"
        )

        #expect(!source.contains("TerminalRuntimeSnapshotFacts"))
        #expect(!source.contains("TerminalRuntimeSnapshotFactProviding"))
    }

    @Test("event identifier supports built-in and plugin tags")
    func eventIdentifierExtensibility() {
        #expect(EventIdentifier.commandFinished.rawValue == "commandFinished")
        #expect(EventIdentifier.plugin("logViewer.lineAppended").rawValue == "logViewer.lineAppended")
    }

    @Test("pane metadata remains available after relocation to pane runtime contracts")
    func paneMetadataRelocation() {
        let metadata = PaneMetadata(title: "X")
        #expect(metadata.title == "X")
        #expect(metadata.paneId.isV7)
        #expect(metadata.contentType == .terminal)
        #expect(metadata.executionBackend == .local)
        #expect(metadata.createdAt.timeIntervalSince1970 > 0)
    }

    @Test("pane context facets carry live worktree metadata")
    func paneContextFacetsCarryLiveWorktreeMetadata() {
        let worktreeId = UUID()
        let repoId = UUID()
        let worktreeURL = URL(fileURLWithPath: "/tmp/worktree")
        let metadata = PaneMetadata(
            launchDirectory: worktreeURL,
            facets: PaneContextFacets(
                repoId: repoId,
                worktreeId: worktreeId,
                cwd: worktreeURL
            )
        )
        #expect(metadata.facets.worktreeId == worktreeId)
        #expect(metadata.facets.repoId == repoId)
    }

    @Test("system source three-tier hierarchy: builtin, service, plugin")
    func systemSourceHierarchy() {
        #expect(
            EventSource.system(.builtin(.filesystemWatcher)).description
                == "system:builtin/filesystemWatcher"
        )
        #expect(
            EventSource.system(.builtin(.securityBackend)).description
                == "system:builtin/securityBackend"
        )
        #expect(
            EventSource.system(.builtin(.coordinator)).description
                == "system:builtin/coordinator"
        )
        #expect(
            EventSource.system(.service(.gitForge(provider: "github"))).description
                == "system:service/gitForge/github"
        )
        #expect(
            EventSource.system(.service(.containerService(provider: "docker"))).description
                == "system:service/containerService/docker"
        )
        #expect(
            EventSource.system(.plugin("mcp-weather")).description
                == "system:plugin/mcp-weather"
        )
    }

    @Test("provider names with special characters produce unambiguous descriptions")
    func systemSourceProviderEscaping() {
        let forgeWithColon = EventSource.system(.service(.gitForge(provider: "my:forge")))
        #expect(forgeWithColon.description == "system:service/gitForge/my:forge")

        let pluginWithSlash = EventSource.system(.plugin("mcp/weather"))
        #expect(pluginWithSlash.description == "system:plugin/mcp/weather")
    }

    @Test("filesystem source identity uses worktree envelope scoped to builtin watcher")
    func filesystemSourceIdentityContract() {
        let worktreeId = UUID()
        let now = ContinuousClock().now
        let envelope = RuntimeEnvelope.worktree(
            WorktreeEnvelope(
                source: .system(.builtin(.filesystemWatcher)),
                seq: 1,
                timestamp: now,
                repoId: worktreeId,
                worktreeId: worktreeId,
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeId,
                            rootPath: URL(fileURLWithPath: "/tmp/worktree-\(UUID().uuidString)"),
                            paths: ["README.md"],
                            timestamp: now,
                            batchSeq: 1
                        )
                    )
                )
            )
        )

        #expect(envelope.source == .system(.builtin(.filesystemWatcher)))
        guard case .worktree(let worktreeEnvelope) = envelope else {
            Issue.record("Expected worktree envelope")
            return
        }
        #expect(worktreeEnvelope.worktreeId == worktreeId)
    }

    private static func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        return try String(contentsOf: projectRoot.appending(path: relativePath), encoding: .utf8)
    }
}
