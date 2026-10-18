import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite(.serialized)
struct TerminalRestoreRuntimeTests {
    private let enabledConfiguration = SessionConfiguration.detect(
        environment: [
            "AGENTSTUDIO_DATA_DIR": "/tmp/fake-zmx-data",
            "AGENTSTUDIO_SESSION_RESTORE": "true",
            "AGENTSTUDIO_TRACE_PROOF_TOKEN": "terminal-restore-runtime-test",
            "AGENTSTUDIO_ZMX_PATH": "/usr/bin/true",
        ],
        isDebugBuild: true
    )

    @Test("restore returns the exact stored opaque identity")
    func restoreReturnsExactStoredOpaqueIdentity() throws {
        let storedText = "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-5566778899001122"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(
            sessionID: storedSessionID,
            launchDirectory: URL(filePath: "/tmp/path-must-not-determine-zmx-identity"),
            facets: PaneContextFacets(
                repoId: UUIDv7.generate(),
                worktreeId: UUIDv7.generate(),
                cwd: URL(filePath: "/tmp/current-cwd-must-not-determine-zmx-identity")
            )
        )
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)

        let restoredSessionID = runtime.zmxSessionID(for: pane)

        #expect(restoredSessionID == storedSessionID)
        #expect(restoredSessionID?.rawValue == storedText)
    }

    @Test("attach command and diagnostics use the exact stored identity")
    func attachCommandAndDiagnosticsUseExactStoredIdentity() throws {
        let storedText = "550E8400-E29B-41D4-A716-446655440000"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(sessionID: storedSessionID)
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)

        let attachCommand = try #require(runtime.zmxAttachCommand(for: pane))
        let diagnostics = try #require(runtime.zmxAttachDiagnostics(for: pane))

        #expect(attachCommand.contains("'\(storedText)'"))
        #expect(diagnostics.sessionId == storedText)
        #expect(diagnostics.socketPath == "\(enabledConfiguration.zmxDir)/\(storedText)")
    }

    @Test("non-zmx terminals do not expose a restorable zmx identity")
    func nonZmxTerminalDoesNotExposeRestorableZmxIdentity() {
        let pane = makeTerminalPane(
            provider: .ghostty,
            lifetime: .temporary,
            sessionID: .generateUUIDv7()
        )
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)

        #expect(runtime.zmxSessionID(for: pane) == nil)
        #expect(runtime.zmxAttachCommand(for: pane) == nil)
        #expect(runtime.zmxAttachDiagnostics(for: pane) == nil)
    }

    @Test("no computed kind (nil) reuses today's plain attach command")
    func noKindReusesTodaysAttachCommand() throws {
        let storedText = "as-nil-kind-plain-attach"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(sessionID: storedSessionID)
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)
        let plainAttachCommand = try #require(runtime.zmxAttachCommand(for: pane))

        #expect(runtime.startupCommand(for: pane, kind: nil) == plainAttachCommand)
    }

    @Test("a cold kind builds the cold-restore command, not the plain attach command")
    func coldKindBuildsColdRestoreCommand() throws {
        let storedText = "as-cold-startup-command"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(sessionID: storedSessionID)
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)
        let plan = try makeFallbackPlan(pane: pane, sessionID: storedSessionID)

        let coldCommand = try #require(runtime.startupCommand(for: pane, kind: .cold(plan)))

        #expect(coldCommand == ZmxBackend.buildColdRestoreCommand(plan))
        #expect(coldCommand.contains(storedText))
        #expect(coldCommand != runtime.zmxAttachCommand(for: pane))
    }

    /// Amended 2026-09-30 ("option A"; S4b): `.warm` no longer reuses the
    /// plain attach command -- it sends its own fallback cold-restore
    /// script, because a real zmx daemon ignores that script for a session
    /// it finds alive (`vendor/zmx/src/loop.zig`'s `ensureSession`), so
    /// sending it changes nothing for a genuinely warm session while
    /// recreating one that died between the liveness check and the
    /// reconnect.
    @Test("a warm kind builds its fallback cold-restore command, not the plain attach command")
    func warmKindBuildsItsFallbackColdRestoreCommand() throws {
        let storedText = "as-warm-startup-command"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(sessionID: storedSessionID)
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)
        let plan = try makeFallbackPlan(pane: pane, sessionID: storedSessionID)

        let warmCommand = try #require(
            runtime.startupCommand(for: pane, kind: .warm(identity: Data([1, 2, 3]), fallback: plan))
        )

        #expect(warmCommand == ZmxBackend.buildColdRestoreCommand(plan))
        #expect(warmCommand != runtime.zmxAttachCommand(for: pane))
    }

    /// Amended 2026-09-30 ("option A"; S4b): same rationale as the warm
    /// case -- an unverified pane also sends its fallback script rather
    /// than attaching plain.
    @Test("an unverified kind builds its fallback cold-restore command, not the plain attach command")
    func unverifiedKindBuildsItsFallbackColdRestoreCommand() throws {
        let storedText = "as-unverified-startup-command"
        let storedSessionID = try makeRestoredZmxSessionID(storedText)
        let pane = makeTerminalPane(sessionID: storedSessionID)
        let runtime = TerminalRestoreRuntime(sessionConfiguration: enabledConfiguration)
        let plan = try makeFallbackPlan(pane: pane, sessionID: storedSessionID)

        let unverifiedCommand = try #require(
            runtime.startupCommand(for: pane, kind: .unverified(.sessionUnresponsive, fallback: plan))
        )

        #expect(unverifiedCommand == ZmxBackend.buildColdRestoreCommand(plan))
        #expect(unverifiedCommand != runtime.zmxAttachCommand(for: pane))
    }

    @Test("disabled session restoration does not build an attach command")
    func disabledSessionRestorationDoesNotBuildAttachCommand() {
        let pane = makeTerminalPane(sessionID: .generateUUIDv7())
        let runtime = TerminalRestoreRuntime(
            sessionConfiguration: SessionConfiguration.detect(
                environment: [
                    "AGENTSTUDIO_DATA_DIR": "/tmp/fake-zmx-data",
                    "AGENTSTUDIO_SESSION_RESTORE": "false",
                    "AGENTSTUDIO_TRACE_PROOF_TOKEN": "terminal-restore-runtime-test",
                    "AGENTSTUDIO_ZMX_PATH": "/usr/bin/true",
                ],
                isDebugBuild: true
            )
        )

        #expect(runtime.zmxAttachCommand(for: pane) == nil)
        #expect(runtime.zmxAttachDiagnostics(for: pane) == nil)
    }

    private func makeTerminalPane(
        provider: SessionProvider = .zmx,
        lifetime: SessionLifetime = .persistent,
        sessionID: ZmxSessionID,
        launchDirectory: URL = URL(filePath: "/tmp"),
        facets: PaneContextFacets = PaneContextFacets()
    ) -> Pane {
        Pane(
            content: .terminal(
                TerminalState(
                    provider: provider,
                    lifetime: lifetime,
                    zmxSessionID: sessionID
                )
            ),
            metadata: PaneMetadata(
                launchDirectory: launchDirectory,
                title: "Terminal",
                facets: facets
            )
        )
    }

    private func makeFallbackPlan(pane: Pane, sessionID: ZmxSessionID) throws -> TerminalColdRestorePlan {
        TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: sessionID,
            zmxExecutablePath: try #require(enabledConfiguration.zmxPath),
            zmxDirectoryPath: enabledConfiguration.zmxDir,
            loginShellPath: "/bin/zsh",
            repositoryMainFolder: nil
        )
    }
}
