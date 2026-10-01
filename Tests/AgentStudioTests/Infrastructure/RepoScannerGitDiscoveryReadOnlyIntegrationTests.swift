import AgentStudioGit
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("RepoScanner discovery-only capability adapter")
struct RepoScannerGitDiscoveryReadOnlyIntegrationTests {
    @Test("validated main and linked evidence preserves exact scanner identity semantics")
    func mapsValidatedMainAndLinkedEvidence() async {
        // Arrange
        let mainPath = URL(fileURLWithPath: "/tmp/discovery-main")
        let linkedPath = URL(fileURLWithPath: "/tmp/discovery-linked")
        let commonDirectory = mainPath.appending(path: ".git")
        let repositoryIdentity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:\(commonDirectory.path)"),
            canonicalCommonDirectory: commonDirectory,
            mainWorktreePath: mainPath
        )
        let mainClient = StubDiscoveryReadClient(
            outcome: .validated(
                evidence(
                    candidatePath: mainPath,
                    gitDirectory: commonDirectory,
                    repositoryIdentity: repositoryIdentity,
                    registration: .main
                )
            )
        )
        let linkedClient = StubDiscoveryReadClient(
            outcome: .validated(
                evidence(
                    candidatePath: linkedPath,
                    gitDirectory: commonDirectory.appending(path: "worktrees/discovery-linked"),
                    repositoryIdentity: repositoryIdentity,
                    registration: .linked(name: "discovery-linked", lockState: .unlocked)
                )
            )
        )

        // Act
        let mainOutcome = await RepoScannerGitDiscoveryClient(
            discoveryReadClient: mainClient
        ).discoveryOutcome(for: mainPath)
        let linkedOutcome = await RepoScannerGitDiscoveryClient(
            discoveryReadClient: linkedClient
        ).discoveryOutcome(for: linkedPath)

        // Assert
        #expect(
            mainOutcome
                == .validated(
                    RepoScanner.ResolvedGitEntry(
                        path: mainPath,
                        kind: .cloneRoot,
                        repositoryKey: repositoryIdentity.id.rawValue
                    )
                )
        )
        #expect(
            linkedOutcome
                == .validated(
                    RepoScanner.ResolvedGitEntry(
                        path: linkedPath,
                        kind: .linkedWorktree(parentClonePath: mainPath),
                        repositoryKey: repositoryIdentity.id.rawValue
                    )
                )
        )
    }

    @Test("package negative and failure outcomes map exhaustively without becoming absence")
    func mapsNegativeAndFailureOutcomesExhaustively() async {
        // Arrange
        let candidatePath = URL(fileURLWithPath: "/tmp/discovery-negative")
        let mappings: [(GitDiscoveryNotRepositoryReason, GitRepositoryAuthoritativeNegativeReason)] = [
            (.exactCandidateIsNotRepository, .exactCandidateIsNotRepository),
            (.invalidRepository, .invalidRepository),
            (.invalidWorktreeRegistration, .invalidWorktreeRegistration),
            (.bareRepository, .bareRepository),
        ]

        // Act / Assert
        for (packageReason, scannerReason) in mappings {
            let outcome = await RepoScannerGitDiscoveryClient(
                discoveryReadClient: StubDiscoveryReadClient(
                    outcome: .notRepository(packageReason)
                )
            ).discoveryOutcome(for: candidatePath)
            #expect(outcome == .authoritativeNegative(scannerReason))
        }

        let failureOutcome = await RepoScannerGitDiscoveryClient(
            discoveryReadClient: StubDiscoveryReadClient(
                outcome: .failed(
                    GitDiscoveryReadFailure(code: -3, errorClass: 7, message: "permission denied")
                )
            )
        ).discoveryOutcome(for: candidatePath)
        guard case .failure(.serviceFailed(let detail)) = failureOutcome else {
            Issue.record("expected non-authoritative service failure, got \(failureOutcome)")
            return
        }
        #expect(detail.contains("code=-3"))
        #expect(detail.contains("permission denied"))
    }

    @Test("canonical mismatch and submodule evidence remain authoritative exclusions")
    func rejectsCanonicalMismatchAndSubmoduleEvidence() async {
        // Arrange
        let candidatePath = URL(fileURLWithPath: "/tmp/discovery-candidate")
        let otherPath = URL(fileURLWithPath: "/tmp/discovery-other")
        let mainGitDirectory = candidatePath.appending(path: ".git")
        let repositoryIdentity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:\(mainGitDirectory.path)"),
            canonicalCommonDirectory: mainGitDirectory,
            mainWorktreePath: candidatePath
        )
        let mismatchClient = StubDiscoveryReadClient(
            outcome: .validated(
                evidence(
                    candidatePath: otherPath,
                    gitDirectory: otherPath.appending(path: ".git"),
                    repositoryIdentity: repositoryIdentity,
                    registration: .main
                )
            )
        )
        let submoduleClient = StubDiscoveryReadClient(
            outcome: .validated(
                evidence(
                    candidatePath: candidatePath,
                    gitDirectory: mainGitDirectory.appending(path: "modules/vendor"),
                    repositoryIdentity: repositoryIdentity,
                    registration: .main
                )
            )
        )

        // Act / Assert
        #expect(
            await RepoScannerGitDiscoveryClient(discoveryReadClient: mismatchClient)
                .discoveryOutcome(for: candidatePath)
                == .authoritativeNegative(.canonicalPathMismatch)
        )
        #expect(
            await RepoScannerGitDiscoveryClient(discoveryReadClient: submoduleClient)
                .discoveryOutcome(for: candidatePath)
                == .authoritativeNegative(.submoduleWorktree)
        )
    }

    @Test("real discovery-only client services compatibility scan loop")
    func realDiscoveryClientServicesCompatibilityLoop() async throws {
        // Arrange
        let root = FileManager.default.temporaryDirectory
            .appending(path: "repo-scanner-discovery-read-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "repository")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await runGit(at: repositoryPath, arguments: ["init"])

        // Act
        let result = await RepoScanner().scan(in: root, maxDepth: 1)

        // Assert
        guard case .completeAuthoritative(let completeScan) = result else {
            Issue.record("expected complete discovery evidence, got \(result)")
            return
        }
        #expect(
            completeScan.verifiedEntries.map {
                $0.path.standardizedFileURL.resolvingSymlinksInPath().path
            }
                == [repositoryPath.standardizedFileURL.resolvingSymlinksInPath().path]
        )
        #expect(completeScan.counts.validationSuccessCount == 1)
    }

    private func evidence(
        candidatePath: URL,
        gitDirectory: URL,
        repositoryIdentity: GitRepositoryIdentity,
        registration: GitDiscoveryWorktreeRegistration
    ) -> GitDiscoveryReadEvidence {
        GitDiscoveryReadEvidence(
            canonicalCandidatePath: candidatePath,
            canonicalWorktreePath: candidatePath,
            canonicalGitDirectory: gitDirectory,
            canonicalCommonDirectory: repositoryIdentity.canonicalCommonDirectory,
            repositoryIdentity: repositoryIdentity,
            registration: registration
        )
    }

    private func runGit(at directory: URL, arguments: [String]) async throws {
        let stderrURL = FileManager.default.temporaryDirectory
            .appending(path: "repo-scanner-git-stderr-\(UUIDv7.generate().uuidString).log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = try await TestToolResolver.resolved().git
        process.arguments = ["-C", directory.path] + arguments
        process.standardError = stderrHandle
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try TestToolResolver.launch(process)
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        TestToolResolver.recordFailedExit(process)
        try stderrHandle.close()
        guard process.terminationStatus == 0 else {
            let errorText = try String(contentsOf: stderrURL, encoding: .utf8)
            Issue.record("git command failed: \(errorText)")
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct StubDiscoveryReadClient: AgentStudioGitDiscoveryReadClient {
    let outcome: GitDiscoveryReadOutcome

    func readDiscoveryCandidate(
        _ request: GitDiscoveryReadRequest
    ) async -> GitDiscoveryReadOutcome {
        outcome
    }
}
