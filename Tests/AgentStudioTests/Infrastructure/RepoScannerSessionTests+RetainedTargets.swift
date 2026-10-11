import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension RepoScannerSessionTests {
    @Test("retained entry identities match the normalized rule table")
    func retainedEntryIdentitiesMatchNormalizedRuleTable() throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: [])
        defer { fixture.remove() }
        let retainedPaths = [
            fixture.root.appending(path: "group/nested"),
            fixture.root.appending(path: "sibling"),
            fixture.root.appending(path: "trailing/"),
            fixture.root.appending(path: "unused/../normalized"),
            fixture.root.appending(path: "./root-dot"),
            fixture.root.appending(path: "too/deep/target"),
            fixture.root,
        ]
        let state = RepoScannerTraversalSession.TraversalState(
            rootURL: fixture.root,
            maxDepth: 2,
            retainedCheckoutPaths: retainedPaths,
            retainedTargetPreparationFailure: nil,
            position: .inspectRoot
        )
        let index = RepoScannerTraversalSession.RetainedTargetIndex(
            rootURL: state.rootURL,
            retainedCheckoutPaths: retainedPaths
        )
        let session = RepoScannerTraversalSession(
            rootURL: state.rootURL,
            maxDepth: state.maxDepth,
            retainedCheckoutPaths: retainedPaths,
            retainedTargetPreparationFailure: nil,
            quantumBudget: .productionDefault,
            capacity: .productionDefault,
            serviceClock: TestPushClock()
        )
        // The rule is exact root-relative identity, never a basename or prefix.
        // Expected keys are literal normalized paths, independent of production.
        let expectedRoot = fixture.root.standardizedFileURL.path
        let cases: [(relativePath: String, depth: Int, expectedPath: String?)] = [
            ("group/nested", 2, expectedRoot + "/group/nested"),
            ("sibling", 1, expectedRoot + "/sibling"),
            ("trailing", 1, expectedRoot + "/trailing"),
            ("normalized", 1, expectedRoot + "/normalized"),
            ("root-dot", 1, expectedRoot + "/root-dot"),
            ("too/deep/target", 3, expectedRoot + "/too/deep/target"),
            ("", 0, expectedRoot),
            ("other/nested", 2, nil),
            ("sibling-extra", 1, nil),
            ("group/nested/child", 3, nil),
            ("nested", 1, nil),
        ]
        let expectedInitialKeys = Set(cases.compactMap { $0.expectedPath })
        #expect(state.remainingRetainedPathKeys == expectedInitialKeys)
        #expect(Set(index.retainedPathKeys) == expectedInitialKeys)

        for testCase in cases {
            // Act: enumerator prefixes may use a physical root alias; only the
            // final `depth` components identify an entry beneath this root.
            let entry = RepoScannerTraversalSession.PendingEnumerationEntry(
                url: URL(fileURLWithPath: "/private/var/enumerator-root")
                    .appending(path: testCase.relativePath),
                depth: testCase.depth
            )
            let matchedPath = index.pathKey(for: entry)

            // Assert
            #expect(matchedPath == testCase.expectedPath)

            for isSymbolicLink in [false, true] {
                // Arrange
                var traversalState = state
                var expectedRemainingKeys = expectedInitialKeys
                if !isSymbolicLink, entry.depth <= state.maxDepth,
                    let expectedPath = testCase.expectedPath
                {
                    expectedRemainingKeys.remove(expectedPath)
                }

                // Act
                session.removeRetainedTargetExaminedByTraversal(
                    entry,
                    isSymbolicLink: isSymbolicLink,
                    state: &traversalState
                )

                // Assert: this synchronous mutation is fully settled on return.
                #expect(traversalState.remainingRetainedPathKeys == expectedRemainingKeys)
            }
        }
    }

    @Test(
        "normalized retained targets preserve cursor and completion across root aliases",
        arguments: [1, 2], [false, true]
    )
    func normalizedRetainedTargetsPreserveSessionOutcomes(maxDepth: Int, useRootAlias: Bool) async throws {
        // Arrange
        let candidateNames = ["group/nested", "sibling", "trailing", "normalized"]
        let fixture = try ScannerSessionFixture(candidateNames: candidateNames)
        defer { fixture.remove() }
        let rootAlias = fixture.root.deletingLastPathComponent()
            .appending(path: fixture.root.lastPathComponent + "-alias")
        if useRootAlias {
            try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.root)
        }
        defer {
            if useRootAlias { try? FileManager.default.removeItem(at: rootAlias) }
        }
        let scanRoot = useRootAlias ? rootAlias : fixture.root
        let canonicalRoot = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let expectedEntries = candidateNames.map { relativePath in
            RepoScanner.ResolvedGitEntry(
                path: canonicalRoot.appending(path: relativePath),
                kind: .cloneRoot,
                repositoryKey: relativePath
            )
        }
        let session = RepoScanner().makeSession(
            in: scanRoot,
            maxDepth: maxDepth,
            retainedCheckoutPaths: [
                scanRoot.appending(path: "group/nested"),
                scanRoot.appending(path: "sibling"),
                scanRoot.appending(path: "trailing/"),
                scanRoot.appending(path: "unused/../normalized"),
                scanRoot.appending(path: "./sibling"),
            ],
            quantumBudget: try oneItemQuantumBudget(),
            serviceClock: TestPushClock()
        )

        // Act
        var suspendedUsages: [RepoScannerQuantumUsage] = []
        let result = await finish(
            session: session,
            outcomesByCanonicalPath: Dictionary(
                uniqueKeysWithValues: expectedEntries.map { ($0.path.path, .validated($0)) }
            ),
            suspendedUsages: &suspendedUsages
        )
        let repeatedOutcome = await session.advanceOneQuantum()

        // Assert: four repositories, plus root and grouping directory, whether
        // the nested repository is traversed or inspected by retained continuation.
        guard case .completeAuthoritative(let completeScan) = result else {
            Issue.record("expected complete scanner evidence, got \(result)")
            return
        }
        #expect(completeScan.verifiedEntries.map(\.repositoryKey).sorted() == candidateNames.sorted())
        #expect(completeScan.counts.directoryVisitCount == 6)
        #expect(completeScan.counts.gitCandidateCount == 4)
        #expect(completeScan.counts.validationSuccessCount == 4)
        #expect(suspendedUsages.allSatisfy { $0.enumeratedItemCount <= 1 })
        #expect(completeScan.counts.scannerServiceInvocationCount == suspendedUsages.count + 5)
        #expect(repeatedOutcome == .finished(result))
    }

}
