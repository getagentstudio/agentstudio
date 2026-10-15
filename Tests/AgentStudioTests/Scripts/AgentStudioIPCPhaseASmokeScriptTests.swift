import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite("AgentStudio IPC Phase A smoke verifier script")
struct AgentStudioIPCPhaseASmokeScriptTests {
    @Test("phase-a verifier is wired through mise and escrow-authenticated pane snapshot calls")
    func phaseAVerifierIsWiredThroughMiseAndEscrowAuthenticatedPaneSnapshotCalls() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("scripts/verify-agentstudio-ipc-phase-a-smoke.sh"),
            encoding: .utf8
        )
        let mise = try String(contentsOf: projectRoot.appendingPathComponent(".mise.toml"), encoding: .utf8)

        #expect(mise.contains("[tasks.verify-agentstudio-ipc-phase-a-smoke]"))
        #expect(mise.contains("/bin/bash scripts/verify-agentstudio-ipc-phase-a-smoke.sh"))
        #expect(script.contains("tmp/debug-observability/latest-observability.env"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_IPC_METADATA"))
        // IPC v2 names an absolute escrow path; the verifier reads token/socket JSON from it.
        #expect(script.contains("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW"))
        #expect(script.contains("IPC_DEBUG_ESCROW_PATH"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE"))
        #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE"))
        #expect(script.contains("requires authenticated IPC auth mode"))
        #expect(script.contains("requires background activation mode"))
        #expect(script.contains("socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)"))
        #expect(script.contains("AGENTSTUDIO_IPC_PHASE_A_SMOKE_RESPONSE_TIMEOUT_SECONDS"))
        #expect(script.contains("self.socket.settimeout(response_timeout_seconds)"))
        #expect(script.contains("IPC response timed out after"))
        #expect(script.contains("\"auth.login\""))
        #expect(script.contains("\"system.capabilities\""))
        #expect(script.contains("\"pane.list\""))
        #expect(script.contains("\"pane.snapshot\""))
        #expect(script.contains("\"handle\": \"pane:1\""))
        #expect(script.contains("\"handle\": canonical_pane_handle"))
        #expect(script.contains("\"command.list\""))
        #expect(script.contains("\"showCommandBarCommands\""))
        #expect(script.contains("\"Command Palette\""))
        #expect(script.contains("\"argumentSchema\""))
        #expect(!script.contains("setRepoSidebarVisibilityMode"))
        #expect(!script.contains("favoritesOnly"))
        #expect(script.contains("\"toggleReposSortDirection\""))
        // Sidebar commands now declare a workspaceWindow argument variant.
        #expect(script.contains("requires_workspace_window(repo_sort_toggle_entry)"))
        #expect(script.contains("workspaceWindowId"))
        #expect(script.contains("first repo sort toggle did not apply"))
        #expect(script.contains("second repo sort toggle did not apply"))
        #expect(script.contains("\"currentRepoOrder\""))
        #expect(script.contains("\"command.execute\""))
        // App command presentation returns a typed `presented` result.
        #expect(script.contains("showCommandBarCommands did not present"))
        #expect(script.contains("get(\"kind\") != \"presented\""))
        #expect(script.contains("\"ui.commandBar.open\""))
        #expect(script.contains("\"scope\": \"commands\""))
        #expect(script.contains("\"workspaceWindowId\""))
        #expect(!script.contains("\"sidebar.surface.set\""))
        #expect(script.contains("\"sidebar.surface.get\""))
        #expect(script.contains("\"sidebar.grouping.set\""))
        #expect(script.contains("\"sidebar.grouping.get\""))
        #expect(script.contains("\"showReposSidebar\""))
        #expect(script.contains("\"showPanesSidebar\""))
        #expect(script.contains("\"setReposGroupingRepo\""))
        #expect(script.contains("\"setReposGroupingActivity\""))
        #expect(script.contains("\"setReposSortFieldName\""))
        #expect(script.contains("\"setReposSortFieldActivity\""))
        #expect(script.contains("\"toggleReposShowsPinned\""))
        #expect(script.contains("\"togglePanesShowsPinned\""))
        #expect(script.contains("retired_panes_organization_commands"))
        #expect(script.contains("removed_panes_organization_commands"))
        for retiredCommand in [
            "setPanesGroupingRepo", "setPanesGroupingTab", "setPanesGroupingActivity",
            "setPanesSubgroupNone", "setPanesSubgroupActivity",
            "setPanesSortFieldName", "setPanesSortFieldActivity", "togglePanesSortDirection",
        ] {
            #expect(script.contains("\"\(retiredCommand)\""))
        }
        #expect(script.contains("command.list omitted retained retired command"))
        #expect(script.contains("removed Panes command remains in command.list"))
        #expect(script.contains("retired command IPC descriptor mismatch"))
        #expect(script.contains("command.execute retired"))
        #expect(script.contains("retired_result.get(\"kind\") != \"unavailable\""))
        #expect(script.contains("featureUnavailable"))
        #expect(script.contains("sidebar.grouping.get panes before retired commands"))
        #expect(script.contains("sidebar.grouping.get panes after retired commands"))
        #expect(script.contains("Panes grouping did not use fixed activity mode"))
        #expect(script.contains("retired Panes organization commands mutated fixed Panes state"))
        #expect(script.contains("\"setInboxGroupingTab\""))
        #expect(script.contains("\"setInboxGroupingRepo\""))
        #expect(script.contains("\"setInboxGroupingPane\""))
        #expect(script.contains("\"setInboxGroupingNone\""))
        #expect(script.contains("\"showInboxNotifications\""))
        #expect(script.contains("\"surface\": \"repo\""))
        #expect(script.contains("\"surface\": \"inbox\""))
        #expect(script.contains("\"mode\": \"none\""))
        #expect(script.contains("\"method not found\""))
        #expect(script.contains("allowed_command_keys"))
        // The typed descriptor catalog rejects unexpected or missing keys.
        #expect(script.contains("command.list descriptor keys mismatch"))
        // IPC v2 escrow remains reusable until app shutdown.
        #expect(script.contains("IPC debug escrow disappeared"))
        #expect(script.contains("\"auth.login replay\""))
        #expect(script.contains("\"unauthenticated\""))
        #expect(!script.contains("--token-stdin"))
        #expect(!script.contains("AGENTSTUDIO_IPC_UNSAFE_NO_AUTH"))
    }

    @Test("phase-a verifier rejects unsafe auth and foreground activation state")
    func phaseAVerifierRejectsUnsafeAuthAndForegroundActivationState() async throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let scriptURL = projectRoot.appendingPathComponent("scripts/verify-agentstudio-ipc-phase-a-smoke.sh")
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-phase-a-state-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dataRoot)
        }
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        let unsafeState = try writePhaseAState(
            root: dataRoot,
            name: "unsafe.env",
            authMode: "unsafe_no_auth",
            activationMode: "background"
        )
        let unsafeResult = try await runPhaseASmokeScript(scriptURL: scriptURL, stateFile: unsafeState)
        #expect(unsafeResult.exitCode == 1)
        #expect(unsafeResult.stderr.contains("requires authenticated IPC auth mode"))

        let foregroundState = try writePhaseAState(
            root: dataRoot,
            name: "foreground.env",
            authMode: "authenticated",
            activationMode: "foreground"
        )
        let foregroundResult = try await runPhaseASmokeScript(scriptURL: scriptURL, stateFile: foregroundState)
        #expect(foregroundResult.exitCode == 1)
        #expect(foregroundResult.stderr.contains("requires background activation mode"))
    }

    private func writePhaseAState(
        root: URL,
        name: String,
        authMode: String,
        activationMode: String
    ) throws -> URL {
        let dataDir = root.appendingPathComponent("data-\(name)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let state = [
            "AGENTSTUDIO_OBSERVABILITY_STATUS=running",
            "AGENTSTUDIO_OBSERVABILITY_PID=\(ProcessInfo.processInfo.processIdentifier)",
            "AGENTSTUDIO_OBSERVABILITY_DATA_DIR=\(dataDir.path)",
            "AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE=\(authMode)",
            "AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE=\(activationMode)",
            "",
        ].joined(separator: "\n")
        let stateURL = root.appendingPathComponent(name)
        try state.write(to: stateURL, atomically: true, encoding: .utf8)
        return stateURL
    }

    private func runPhaseASmokeScript(scriptURL: URL, stateFile: URL) async throws -> ProcessResult {
        try await RunToExitProcessExecutor().execute(
            command: "/bin/bash",
            args: [scriptURL.path],
            cwd: nil,
            environment: [
                "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path
            ]
        )
    }
}
