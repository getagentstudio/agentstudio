import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge File manifest keyed revisions")
struct BridgeWorktreeFileManifestRevisionTests {
    @Test("member status mints with the File index and retains last-good facts when stale")
    func memberStatusSharesIndexRevisionMinter() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 0)
        defer { fixture.remove() }
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1,
            rootURL: fixture.rootURL,
            productAdmission: fixture.productAdmission.context,
            source: source
        )
        let initial = await index.captureKeyedSnapshot()
        #expect(initial.records.isEmpty)
        #expect(initial.memberStatus.revision == 1)
        #expect(initial.memberStatus.record.status == .loading)
        #expect(initial.targetRevision == 1)

        #expect(
            try await index.updateMemberStatus(
                state: .ready,
                branchName: "main",
                ahead: 2,
                behind: 1,
                staged: 3,
                unstaged: 4,
                untracked: 5,
                productAdmission: fixture.productAdmission.context
            ))
        let prepared = await index.captureKeyedSnapshot()
        #expect(prepared.memberStatus.record.status == .loading)
        #expect(!prepared.isEnumerationComplete)
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        #expect(
            await index.markEnumerationComplete(
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        #expect(
            try await index.updateMemberStatus(
                state: .stale,
                branchName: nil,
                ahead: nil,
                behind: nil,
                staged: nil,
                unstaged: nil,
                untracked: nil,
                productAdmission: fixture.productAdmission.context
            ))
        let stale = await index.captureKeyedSnapshot()
        #expect(stale.memberStatus.revision == 3)
        #expect(stale.targetRevision == 3)
        #expect(stale.memberStatus.record.status == .stale)
        #expect(stale.memberStatus.record.branchName == "main")
        #expect(stale.memberStatus.record.ahead == 2)
        #expect(stale.memberStatus.record.staged == 3)
    }

    @Test("descriptor attempts mint with the current File row and reject stale success and unavailable")
    func descriptorAttemptsAreGuardedByTheIndex() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1, rootURL: fixture.rootURL, productAdmission: fixture.productAdmission.context, source: source
        )
        let row = testRow(path: fixture.demandedPath)
        let first = try testPayload(path: row.path, descriptorID: "descriptor-a", source: source)
        let second = try testPayload(path: row.path, descriptorID: "descriptor-b", source: source)
        #expect(
            await index.appendEnumeratedRows(
                [row], productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        let oldAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 1,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        let newAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 1,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        #expect(oldAttempt != nil && newAttempt != nil)
        if let oldAttempt, let newAttempt {
            #expect(!(await index.acceptDescriptorOutcome(first, for: oldAttempt)))
            #expect(await index.acceptDescriptorOutcome(second, for: newAttempt))
        }
        let installed = await index.captureKeyedSnapshot()
        #expect(installed.targetRevision == 3)
        #expect(installed.records.first?.descriptorOutcome == second)
        #expect(installed.records.first?.revision == 3)

        let staleUnavailable = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 2,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        #expect(
            await index.invalidateDescriptor(
                for: row.path, productAdmission: fixture.productAdmission.context
            ))
        if let staleUnavailable {
            let unavailable = try testPayload(
                path: row.path, descriptorID: "descriptor-unavailable", source: source,
                unavailable: true
            )
            #expect(!(await index.acceptDescriptorOutcome(unavailable, for: staleUnavailable)))
        }
        #expect((await index.captureKeyedSnapshot()).records.first?.descriptorOutcome == nil)

        let beforeDelete = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 2,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        _ = await index.removePaths(
            [row.path], productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: foreground
        )
        #expect(
            await index.appendEnumeratedRows(
                [row], productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        if let beforeDelete {
            #expect(!(await index.acceptDescriptorOutcome(first, for: beforeDelete)))
        }
        #expect((await index.captureKeyedSnapshot()).records.first?.descriptorOutcome == nil)

        let currentAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 2,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let currentAttempt {
            #expect(await index.acceptDescriptorOutcome(first, for: currentAttempt))
        }
        // A failed downstream emit has no rollback operation on the canonical index.
        #expect((await index.captureKeyedSnapshot()).records.first?.descriptorOutcome == first)
    }

    @Test("issued A remains eligible after B installs, and revocation releases interim identity")
    func retainedDescriptorLeaseKeepsExactIssuedIdentity() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1, rootURL: fixture.rootURL, productAdmission: fixture.productAdmission.context, source: source
        )
        let row = testRow(path: fixture.demandedPath)
        let first = try testPayload(path: row.path, descriptorID: "descriptor-a", source: source)
        let second = try testPayload(path: row.path, descriptorID: "descriptor-b", source: source)
        #expect(
            await index.appendEnumeratedRows(
                [row], productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        let firstAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 1,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let firstAttempt { #expect(await index.acceptDescriptorOutcome(first, for: firstAttempt)) }
        let canonicalKey = fixture.demandedFileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let retained = await index.retainCurrentDescriptor(
            for: canonicalKey, productAdmission: fixture.productAdmission.context
        )
        #expect(retained != nil)
        let secondAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 2,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let secondAttempt { #expect(await index.acceptDescriptorOutcome(second, for: secondAttempt)) }
        if case .available(let firstDescriptor) = first.availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: firstDescriptor, productAdmission: fixture.productAdmission.context
                ) == first)
            if let retained { await index.releaseRetainedDescriptor(retained) }
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: firstDescriptor, productAdmission: fixture.productAdmission.context
                ) == first)
        }
        let secondLease = await index.retainCurrentDescriptor(
            for: canonicalKey, productAdmission: fixture.productAdmission.context
        )
        #expect(secondLease != nil)
        #expect(await index.retainedDescriptorLeaseCount == 1)
        fixture.productAdmission.close()
        await index.revokeRetainedDescriptors()
        #expect(await index.retainedDescriptorLeaseCount == 0)
        #expect(await index.formerIssuedDescriptorCount == 0)
    }

    @Test("the bounded interim evicts least recently read non-newest descriptors")
    func formerIssuedDescriptorBudgetKeepsNewest() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1,
            rootURL: fixture.rootURL,
            productAdmission: fixture.productAdmission.context,
            source: source,
            maximumFormerDescriptorCount: 2,
            maximumFormerDescriptorEncodedBytes: 256 * 1024
        )
        let row = testRow(path: fixture.demandedPath)
        #expect(
            await index.appendEnumeratedRows(
                [row], productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        let payloads = try ["descriptor-a", "descriptor-b", "descriptor-c", "descriptor-d"].map {
            try testPayload(path: row.path, descriptorID: $0, source: source)
        }
        for (offset, payload) in payloads.prefix(3).enumerated() {
            let attempt = await index.reserveDescriptorAttempt(
                for: row.path, source: source, memberIncarnation: "default", interestRevision: offset + 1,
                productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
            )
            if let attempt { #expect(await index.acceptDescriptorOutcome(payload, for: attempt)) }
        }
        if case .available(let firstDescriptor) = payloads[0].availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: firstDescriptor, productAdmission: fixture.productAdmission.context
                ) == payloads[0]
            )
        }
        let latestAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 4,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let latestAttempt {
            #expect(await index.acceptDescriptorOutcome(payloads[3], for: latestAttempt))
        }
        #expect(await index.formerIssuedDescriptorCount == 2)
        if case .available(let secondDescriptor) = payloads[1].availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: secondDescriptor, productAdmission: fixture.productAdmission.context
                ) == nil
            )
        }
        if case .available(let firstDescriptor) = payloads[0].availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: firstDescriptor, productAdmission: fixture.productAdmission.context
                ) == payloads[0]
            )
        }
        if case .available(let newestDescriptor) = payloads[3].availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: newestDescriptor, productAdmission: fixture.productAdmission.context
                ) == payloads[3]
            )
        }
    }

    @Test("the encoded-byte cap evicts a former descriptor without evicting the newest")
    func formerIssuedDescriptorByteBudget() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1,
            rootURL: fixture.rootURL,
            productAdmission: fixture.productAdmission.context,
            source: source,
            maximumFormerDescriptorCount: 2,
            maximumFormerDescriptorEncodedBytes: 1
        )
        let row = testRow(path: fixture.demandedPath)
        #expect(
            await index.appendEnumeratedRows(
                [row], productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ))
        let first = try testPayload(path: row.path, descriptorID: "descriptor-a", source: source)
        let second = try testPayload(path: row.path, descriptorID: "descriptor-b", source: source)
        let firstAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 1,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let firstAttempt { #expect(await index.acceptDescriptorOutcome(first, for: firstAttempt)) }
        let secondAttempt = await index.reserveDescriptorAttempt(
            for: row.path, source: source, memberIncarnation: "default", interestRevision: 2,
            productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground
        )
        if let secondAttempt { #expect(await index.acceptDescriptorOutcome(second, for: secondAttempt)) }
        #expect(await index.formerIssuedDescriptorCount == 0)
        #expect(await index.formerIssuedDescriptorByteCount == 0)
        if case .available(let firstDescriptor) = first.availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: firstDescriptor, productAdmission: fixture.productAdmission.context
                ) == nil
            )
        }
        if case .available(let newestDescriptor) = second.availability {
            #expect(
                await index.issuedDescriptorOutcome(
                    matching: newestDescriptor, productAdmission: fixture.productAdmission.context
                ) == second
            )
        }
    }

    @Test("evicted issued File content ends typed unavailable and source cancellation drains the interim")
    // WIP checkpoint: split setup and terminal assertions before the 1.4c cutover commit.
    // swiftlint:disable:next function_body_length
    func evictedDescriptorContentAndSourceRetirement() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try ProductFileSourceFixture(
            fileCount: 1,
            productAdmission: harness.productAdmission
        )
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let collector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: fixture.viewDemand(),
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }
        let firstDescriptor = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileContentDescriptor? in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return nil }
                return descriptor
            }.first
        )
        let contexts = await source.contextBySubscriptionId
        let context = try #require(contexts[openSnapshot.subscriptionId])
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        for replacement in 0...AppPolicies.Bridge.fileRetainedDescriptorMaximumCount {
            let attempt = try #require(
                await context.manifestIndex.reserveDescriptorAttempt(
                    for: fixture.demandedPath,
                    source: context.productSource,
                    memberIncarnation: "default",
                    interestRevision: replacement + 2,
                    productAdmission: fixture.productAdmission.context,
                    foregroundWorkAdmission: foreground
                ))
            let payload = try testPayload(
                path: fixture.demandedPath,
                descriptorID: "replacement-\(replacement)",
                source: context.productSource
            )
            #expect(await context.manifestIndex.acceptDescriptorOutcome(payload, for: attempt))
        }
        #expect(
            await context.manifestIndex.formerIssuedDescriptorCount
                == AppPolicies.Bridge.fileRetainedDescriptorMaximumCount
        )
        let fileRequest = try fixture.contentRequest(descriptor: firstDescriptor)
        #expect(
            await source.contentReadPlan(
                for: fileRequest,
                productAdmission: fixture.productAdmission.context
            ) == nil
        )

        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let request = BridgeProductContentRequest.fileContent(fileRequest)
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in
            await provider.runContentProducer(
                request: request,
                lease: lease,
                productAdmission: harness.productAdmission.context,
                session: harness.session
            )
        }
        let lease = try bridgeProductAcceptedLease(registration)
        let opening = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            ))
        let decoder = try BridgeProductContentFrameDecoder()
        let openingFrames = try decoder.append(opening.data)
        #expect(openingFrames.contains { if case .accepted = $0.header { true } else { false } })
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try bridgeProductOpeningContentAcknowledgement(for: request),
                productAdmission: harness.productAdmission.context
            )
        )
        let terminal = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            ))
        let terminalFrames = try decoder.append(terminal.data)
        if case .error(let errorHeader) = terminalFrames.last?.header {
            #expect(errorHeader.code == .superseded)
            #expect(errorHeader.retryable)
        } else {
            Issue.record("Expected a typed unavailable content terminal for the evicted descriptor")
        }
        try await harness.closeProducer(lease)

        await source.cancel(subscriptionId: openSnapshot.subscriptionId)
        #expect(await context.manifestIndex.formerIssuedDescriptorCount == 0)
        #expect(await context.manifestIndex.formerIssuedDescriptorByteCount == 0)
        #expect(
            await source.contentReadPlan(
                for: fileRequest,
                productAdmission: fixture.productAdmission.context
            ) == nil
        )
    }

    @Test("one index mints revisions during accepted writes and freezes a tombstone with its target")
    func revisionsAndTombstonesFollowCommittedState() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let source = try testSource()
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1,
            rootURL: fixture.rootURL,
            productAdmission: fixture.productAdmission.context,
            source: source
        )
        let original = BridgeWorktreeTreeRowMetadata(
            rowId: "file-row-1",
            path: fixture.demandedPath,
            name: fixture.demandedPath,
            parentPath: nil,
            depth: 0,
            isDirectory: false,
            fileId: "file-1",
            fileClass: .source,
            sizeBytes: 4,
            lineCount: 1,
            changeStatus: nil
        )
        let admitted = await index.appendEnumeratedRows(
            [original],
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: foreground
        )
        #expect(admitted)
        let first = await index.captureKeyedSnapshot()
        let canonicalKey = fixture.demandedFileURL.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(first.targetRevision == 2)
        #expect(first.records.first?.key == canonicalKey)
        #expect(first.records.first?.revision == 2)

        let duplicate = await index.upsertRows([original], productAdmission: fixture.productAdmission.context)
        #expect(duplicate)
        #expect((await index.captureKeyedSnapshot()).targetRevision == 2)

        let changed = BridgeWorktreeTreeRowMetadata(
            rowId: original.rowId,
            path: original.path,
            name: original.name,
            parentPath: original.parentPath,
            depth: original.depth,
            isDirectory: original.isDirectory,
            fileId: original.fileId,
            fileClass: original.fileClass,
            sizeBytes: 8,
            lineCount: 2,
            changeStatus: "modified"
        )
        let updated = await index.upsertRows([changed], productAdmission: fixture.productAdmission.context)
        #expect(updated)
        #expect((await index.captureKeyedSnapshot()).records.first?.revision == 3)

        let removed = await index.removePaths(
            [fixture.demandedPath],
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: foreground
        )
        guard case .applied = removed else {
            Issue.record("Expected an admitted File removal")
            return
        }
        let afterDelete = await index.captureKeyedSnapshot()
        #expect(afterDelete.targetRevision == 4)
        #expect(afterDelete.records.isEmpty)
        #expect(afterDelete.tombstoneRevisionByKey[canonicalKey] == 4)

        let completed = await index.markEnumerationComplete(
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: foreground
        )
        let canonicalRoot = fixture.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let certified = await index.certifyCompleteAbsence(
            in: canonicalRoot,
            upTo: afterDelete.targetRevision
        )
        let afterCertification = await index.captureKeyedSnapshot()
        #expect(completed && certified)
        #expect(afterCertification.tombstoneRevisionByKey.isEmpty)
        #expect(afterCertification.absenceFloorRevisionByRange[canonicalRoot] == 4)
        #expect(!(await index.acceptsExistingRevision(3, for: canonicalKey)))
        #expect(await index.acceptsExistingRevision(5, for: canonicalKey))

        fixture.productAdmission.close()
        let staleAccepted = await index.upsertRows([changed], productAdmission: fixture.productAdmission.context)
        let afterStaleInput = await index.captureKeyedSnapshot()
        #expect(!staleAccepted)
        #expect(afterStaleInput.targetRevision == 4)
    }
}

private func testRow(path: String) -> BridgeWorktreeTreeRowMetadata {
    .init(
        rowId: "file-row-1", path: path, name: path, parentPath: nil, depth: 0,
        isDirectory: false, fileId: "file-1", fileClass: .source, sizeBytes: 4,
        lineCount: 1, changeStatus: nil
    )
}

private func testSource() throws -> BridgeProductFileSourceIdentity {
    let data = Data(
        """
        {"repoId":"00000000-0000-4000-8000-000000000001","rootRevisionToken":null,
        "sourceCursor":"source-cursor-1","sourceId":"source-1","subscriptionGeneration":1,
        "worktreeId":"00000000-0000-4000-8000-000000000002"}
        """.utf8
    )
    return try BridgeProductStrictJSON.decode(BridgeProductFileSourceIdentity.self, from: data)
}

private func testPayload(
    path: String,
    descriptorID: String,
    source: BridgeProductFileSourceIdentity,
    unavailable: Bool = false
) throws -> BridgeProductFileDescriptorReadyPayload {
    let descriptor = try BridgeProductFileContentDescriptor(
        declaredByteLength: 4, descriptorId: descriptorID,
        expectedSha256: String(repeating: "a", count: 64), fileId: "file-1",
        maximumBytes: 4, source: source,
        window: BridgeProductFileContentWindow(maximumBytes: 4, maximumLines: 10)
    )
    return try .init(
        availability: unavailable ? .unavailable(.unreadable) : .available(descriptor),
        encoding: unavailable ? nil : .utf8,
        endsMidLine: false,
        endsWithNewline: !unavailable,
        estimatedContentHeightPixels: nil,
        fileExtension: "txt",
        fileId: "file-1",
        language: nil,
        modifiedAtUnixMilliseconds: nil,
        path: path,
        payloadByteCount: unavailable ? 0 : 4,
        payloadLineCount: unavailable ? 0 : 1,
        rowId: "file-row-1",
        sizeBytes: 4,
        source: source,
        totalLineCount: unavailable ? nil : 1,
        truncationKind: .complete,
        virtualizedExtentKind: unavailable ? .unavailable : .exactLineCount
    )
}
