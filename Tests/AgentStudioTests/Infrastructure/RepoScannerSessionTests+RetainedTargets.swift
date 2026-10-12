import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension RepoScannerSessionTests {
    @Test(
        "private-prefixed entries remove targets already shortened at initialization",
        arguments: ["/tmp", "/private/tmp"]
    )
    func privatePrefixedEntryRemovesAlreadyExistingRetainedTarget(retainedParentPath: String) throws {
        // Arrange: both literal retained spellings shorten before the index is built.
        let targetName = "repo-scanner-private-existing-\(UUIDv7.generate().uuidString)"
        let privatePath = URL(fileURLWithPath: "/private/tmp/\(targetName)")
        try FileManager.default.createDirectory(at: privatePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privatePath) }
        let retainedPath = URL(fileURLWithPath: "\(retainedParentPath)/\(targetName)")
        let rootURL = URL(fileURLWithPath: "/")
        let index = RepoScannerTraversalSession.RetainedTargetIndex(
            rootURL: rootURL,
            retainedCheckoutPaths: [retainedPath]
        )
        let session = RepoScannerTraversalSession(
            rootURL: rootURL,
            maxDepth: 3,
            retainedCheckoutPaths: [retainedPath],
            retainedTargetPreparationFailure: nil,
            quantumBudget: .productionDefault,
            capacity: .productionDefault,
            serviceClock: TestPushClock()
        )
        var state = RepoScannerTraversalSession.TraversalState(
            rootURL: rootURL,
            maxDepth: 3,
            retainedCheckoutPaths: [retainedPath],
            retainedTargetPreparationFailure: nil,
            position: .inspectRoot
        )
        let entry = RepoScannerTraversalSession.PendingEnumerationEntry(url: privatePath, depth: 3)
        let expectedPathKey = "/tmp/\(targetName)"
        #expect(index.retainedPathKeys == [expectedPathKey])
        #expect(state.remainingRetainedPathKeys == Set([expectedPathKey]))

        // Act
        let matchedPath = index.pathKey(for: entry)
        session.removeRetainedTargetExaminedByTraversal(entry, isSymbolicLink: false, state: &state)

        // Assert: root / plus private/tmp/name uses the inspection-time key,
        // regardless of the retained spelling. The synchronous removal is settled.
        #expect(matchedPath == expectedPathKey)
        #expect(state.remainingRetainedPathKeys.isEmpty)
    }

    @Test("private retained target created after suspension keeps the inspection-time skip")
    func privateRetainedTargetCreatedAfterSuspensionIsSkipped() async throws {
        // Arrange: the shortened alias does not exist when custody captures its keys.
        let targetName = "repo-scanner-private-continuation-\(UUIDv7.generate().uuidString)"
        let retainedPath = URL(fileURLWithPath: "/private/tmp/\(targetName)")
        defer { try? FileManager.default.removeItem(at: retainedPath) }
        #expect(retainedPath.standardizedFileURL.path == "/private/tmp/\(targetName)")
        let session = RepoScanner().makeSession(
            in: URL(fileURLWithPath: "/"),
            maxDepth: 0,
            retainedCheckoutPaths: [retainedPath],
            quantumBudget: try oneItemQuantumBudget(),
            serviceClock: TestPushClock()
        )
        defer { _ = session.cancel() }
        let rootOutcome = await session.advanceOneQuantum()
        guard case .suspended(let rootUsage) = rootOutcome else {
            Issue.record("expected root inspection to suspend before retained continuation, got \(rootOutcome)")
            return
        }
        #expect(rootUsage.enumeratedItemCount == 1)
        #expect(rootUsage.candidateValidationCount == 0)
        let facts = FactRecorder<RepoScannerSessionID, RepoScannerQuantumOutcome>(
            vocabulary: FactVocabulary(
                describeScope: { $0.rawValue.uuidString },
                describeFact: { String(describing: $0) },
                isClosing: { _, outcome in
                    if case .finished = outcome { return true }
                    return false
                }
            )
        )
        let opening = await facts.mark(session.id)

        // Act: Foundation now shortens this spelling, before its continuation turn.
        try FileManager.default.createDirectory(
            at: retainedPath.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        #expect(retainedPath.standardizedFileURL.path == "/tmp/\(targetName)")
        var resumedUsages: [RepoScannerQuantumUsage] = []
        let result: RepoScannerResult
        scanQuanta: while true {
            let outcome = await session.advanceOneQuantum()
            facts.append(scope: session.id, fact: outcome)
            switch outcome {
            case .suspended(let usage):
                resumedUsages.append(usage)
            case .validationRequired(let request):
                // Settle any unexpected request so the negative closes at real completion.
                #expect(
                    session.consumeValidationCompletion(
                        .init(
                            request: request,
                            outcome: .authoritativeNegative(.notAValidWorktree),
                            validationServiceDuration: .zero
                        )
                    ) == .consumed
                )
            case .finished(let completed):
                result = completed
                break scanQuanta
            }
        }

        // Assert: one skipped retained item, then exhaustion; no validation in this session.
        await #expect(throws: Never.self) {
            try await facts.expectNone(
                of: {
                    if case .validationRequired = $0 { return true }
                    return false
                },
                "retained validation request",
                from: opening,
                closedBy: { $0 == .finished(result) }
            )
        }
        try await facts.finish()
        guard case .completeAuthoritative(let completeScan) = result else {
            Issue.record("expected inspection-time skip to remain complete, got \(result)")
            return
        }
        #expect(completeScan.verifiedEntries.isEmpty)
        #expect(
            completeScan.counts
                == RepoScannerEvidenceCounts(
                    directoryVisitCount: 1,
                    directoryTraversalFailureCount: 0,
                    entryMetadataFailureCount: 0,
                    gitCandidateCount: 0,
                    validationSuccessCount: 0,
                    validationAuthoritativeNegativeCount: 0,
                    validationTimeoutCount: 0,
                    validationCancellationCount: 0,
                    validationFailureCount: 0,
                    scannerServiceInvocationCount: 3
                )
        )
        #expect(resumedUsages.count == 1)
        #expect(resumedUsages.first?.enumeratedItemCount == 1)
        #expect(resumedUsages.first?.candidateValidationCount == 0)
        #expect(await session.advanceOneQuantum() == .finished(result))
    }

    @Test("private entry and root keys follow the filesystem at inspection", arguments: ["/private", "/"])
    func privateEntryMembershipUsesInspectionTimeKey(rootPath: String) throws {
        // Arrange: cover a private-spelled root and a private-spelled retained match.
        let targetName = "repo-scanner-private-membership-\(UUIDv7.generate().uuidString)"
        let retainedPath = URL(fileURLWithPath: "/private/tmp/\(targetName)")
        defer { try? FileManager.default.removeItem(at: retainedPath) }
        let rootURL = URL(fileURLWithPath: rootPath)
        let index = RepoScannerTraversalSession.RetainedTargetIndex(
            rootURL: rootURL,
            retainedCheckoutPaths: [retainedPath]
        )
        let rootVisitIndex = RepoScannerTraversalSession.RetainedTargetIndex(
            rootURL: retainedPath,
            retainedCheckoutPaths: [retainedPath]
        )
        let session = RepoScannerTraversalSession(
            rootURL: rootURL,
            maxDepth: 3,
            retainedCheckoutPaths: [retainedPath],
            retainedTargetPreparationFailure: nil,
            quantumBudget: .productionDefault,
            capacity: .productionDefault,
            serviceClock: TestPushClock()
        )
        var state = RepoScannerTraversalSession.TraversalState(
            rootURL: rootURL,
            maxDepth: 3,
            retainedCheckoutPaths: [retainedPath],
            retainedTargetPreparationFailure: nil,
            position: .inspectRoot
        )
        let entry = RepoScannerTraversalSession.PendingEnumerationEntry(
            url: retainedPath,
            depth: rootPath == "/" ? 3 : 2
        )
        let initialKeys: Set<String> = ["/private/tmp/\(targetName)"]
        #expect(state.remainingRetainedPathKeys == initialKeys)
        #expect(index.pathKey(for: entry) == "/private/tmp/\(targetName)")
        #expect(rootVisitIndex.rootPathKey == "/private/tmp/\(targetName)")

        // Act
        try FileManager.default.createDirectory(at: retainedPath, withIntermediateDirectories: true)
        let matchedPath = index.pathKey(for: entry)
        session.removeRetainedTargetExaminedByTraversal(entry, isSymbolicLink: false, state: &state)

        // Assert: root plus the final depth components now shortens to /tmp.
        // That new key cannot remove the original private-spelled custody key.
        #expect(matchedPath == "/tmp/\(targetName)")
        #expect(state.remainingRetainedPathKeys == initialKeys)
        #expect(rootVisitIndex.rootPathKey == "/tmp/\(targetName)")
    }

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
