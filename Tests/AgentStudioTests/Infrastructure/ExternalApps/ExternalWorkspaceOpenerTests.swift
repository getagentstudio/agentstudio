import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@MainActor
@Suite(.serialized)
struct ExternalWorkspaceOpenerTests {
    @Test(
        "F11 awaited editor launch returns its eventual result through the existing target requests",
        arguments: [false, true])
    func awaitedEditorUsesTheCompletedLaunchResult(launchSucceeded: Bool) async throws {
        let path = URL(fileURLWithPath: "/tmp/owned-pane-context-file.txt")
        let held = HeldStep<ExternalWorkspaceOpener.OpenRequest>("awaited editor launch")
        let operation = Task {
            defer { held.retire() }
            return await ExternalWorkspaceOpener.openInEditorAwaiting(
                id: ExternalEditorTarget.windsurf.id, path: path, installedTargets: [.windsurf],
                runner: { request in
                    do { try await held.arrive(request) } catch { return false }
                    return launchSucceeded
                })
        }
        do {
            let request = try await held.firstArrival()
            #expect(request == .application(bundleIdentifier: "com.exafunction.windsurf", targetPath: path))
            held.release()
            #expect(await operation.value == launchSucceeded)
            #expect(held.recordedArrivals == [request])
        } catch {
            held.retire()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("F11 awaited editor refuses an uninstalled bookmark without invoking the launch effect")
    func awaitedEditorRefusesMissingTarget() async {
        var attempted: [ExternalWorkspaceOpener.OpenRequest] = []
        let result = await ExternalWorkspaceOpener.openInEditorAwaiting(
            id: "missing", path: URL(fileURLWithPath: "/tmp/owned-pane-context-file.txt"), installedTargets: [],
            runner: { request in
                attempted.append(request)
                return true
            })
        #expect(!result)
        #expect(attempted.isEmpty)
    }

    @Test
    func openInEditor_usesTargetRequests() {
        let path = URL(fileURLWithPath: "/tmp/agent studio")

        let requests = ExternalWorkspaceOpener.requests(
            for: .cursor,
            path: path
        )

        #expect(
            requests == [
                .application(
                    bundleIdentifier: ExternalEditorTarget.cursor.bundleIdentifier,
                    targetPath: path
                ),
                .command(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["cursor", "--reuse-window", "/tmp/agent studio"]
                ),
            ]
        )
    }

    @Test
    func requests_useExplicitBookmarkedTarget() {
        let path = URL(fileURLWithPath: "/tmp/project")
        let installedTargets: [ExternalEditorTarget] = [.windsurf, .vscode]

        let target = ExternalEditorTarget.resolveBookmarkedOrDefault(
            bookmarkedEditorId: "vscode",
            installedTargets: installedTargets
        )

        guard case .resolved(let resolvedTarget) = target else {
            Issue.record("Expected bookmarked target resolution")
            return
        }
        #expect(resolvedTarget.id == "vscode")
        #expect(
            ExternalWorkspaceOpener.requests(for: resolvedTarget, path: path) == [
                .application(
                    bundleIdentifier: ExternalEditorTarget.vscode.bundleIdentifier,
                    targetPath: path
                ),
                .command(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["code", "--reuse-window", "/tmp/project"],
                ),
            ]
        )
    }

    @Test
    func openInEditor_returnsFalseForUnknownTarget() {
        let success = ExternalWorkspaceOpener.openInEditor(
            id: "unknown",
            path: URL(fileURLWithPath: "/tmp/project"),
            installedTargets: [.cursor, .vscode]
        )

        #expect(!success)
    }

    @Test
    func open_requestsStopAtFirstSuccess() {
        let path = URL(fileURLWithPath: "/tmp/project")
        var attemptedRequests: [ExternalWorkspaceOpener.OpenRequest] = []

        let success = ExternalWorkspaceOpener.open(
            requests: ExternalWorkspaceOpener.requests(for: .vscode, path: path),
            runner: { request in
                attemptedRequests.append(request)
                if case .application(bundleIdentifier: ExternalEditorTarget.vscode.bundleIdentifier, targetPath: path) =
                    request
                {
                    return true
                }
                return false
            }
        )

        #expect(success)
        #expect(
            attemptedRequests == [
                .application(bundleIdentifier: ExternalEditorTarget.vscode.bundleIdentifier, targetPath: path)
            ]
        )
    }

    @Test
    func openAsync_requestsFallbackToCommandWhenApplicationFails() async {
        let path = URL(fileURLWithPath: "/tmp/project")
        var attemptedRequests: [ExternalWorkspaceOpener.OpenRequest] = []

        let success = await ExternalWorkspaceOpener.openAsync(
            requests: ExternalWorkspaceOpener.requests(for: .vscode, path: path),
            runner: { request in
                attemptedRequests.append(request)
                if case .application = request {
                    return false
                }
                return true
            }
        )

        #expect(success)
        #expect(
            attemptedRequests == [
                .application(
                    bundleIdentifier: ExternalEditorTarget.vscode.bundleIdentifier,
                    targetPath: path
                ),
                .command(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["code", "--reuse-window", "/tmp/project"],
                ),
            ]
        )
    }
}
