import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File tracked symlink alias descriptor publication")
struct BridgeProductFileSymlinkAliasTests {
    @Test("tracked AGENTS aliases keep independent descriptors and seal without Retry")
    func trackedAliasesDoNotInvalidateDescriptorBatch() async throws {
        let fixture = try await SymlinkAliasGitFixture.make()
        defer { FilesystemTestGitRepo.destroy(fixture.rootURL) }
        let admission = try BridgeProductAdmissionTestContext.make()
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let construction = BridgeWorktreeProductConstructionCoordinator()
        let source = BridgePaneProductFileMetadataSource(
            authority: .init(paneId: UUIDv7.generate(), worktree: fixture.worktree),
            gitReadContext: makeBridgeGitReadContext(rootURL: fixture.rootURL), constructionCoordinator: construction,
            statusProvider: ProductFileSourceStatusProvider())
        let spec = try fixture.sourceSpec()
        let subscription = BridgeProductSubscriptionSnapshot(
            subscription: .fileMetadata(spec), subscriptionId: "symlink-file-metadata", subscriptionKind: .fileMetadata,
            workerDerivationEpoch: 1)
        let demand = try fixture.demand()
        let reconciler = BridgeFileSurfaceReconciler()
        let inputBasis = BridgeFileSurfaceInputBasis.admitted(source: spec, scope: fixture.scope)
        var nextAction = await reconciler.beginAttempt(inputBasis: inputBasis)
        var successfulCycle: Int?
        var sealedSnapshot: BridgeWorktreeFileKeyedSnapshot?
        for cycle in 1...2 {
            guard case .start(let attempt) = nextAction else {
                Issue.record("Expected File attempt for initial publication or explicit Retry")
                break
            }
            try await source.open(
                subscription: subscription, productAdmission: admission.context,
                foregroundWorkAdmission: foreground.admission, emit: { _ in })
            try await source.applyViewDemand(
                subscriptionId: subscription.subscriptionId, demand: demand, productAdmission: admission.context,
                foregroundWorkAdmission: foreground.admission, forceRecapture: true, emit: { _ in })
            let snapshot = try #require(
                await source.captureKeyedSnapshot(
                    subscriptionId: subscription.subscriptionId, demand: demand, productAdmission: admission.context))
            let aliases = snapshot.records.filter { fixture.trackedPaths.contains($0.row.path) }
            print("GO21 cycle=\(cycle) paths=\(aliases.map(\.row.path)),uniqueKeys=\(Set(aliases.map(\.key)).count)")
            #expect(Set(aliases.map(\.row.path)) == fixture.trackedPaths)
            #expect(aliases.count == 3)
            #expect(Set(aliases.map(\.key)).count == 3)
            let canonicalRoot = fixture.rootURL.standardizedFileURL.resolvingSymlinksInPath()
            for record in aliases {
                #expect(record.key == canonicalRoot.appending(path: record.row.path).standardizedFileURL.path)
                #expect(record.descriptorOutcome?.path == record.row.path)
                #expect(record.descriptorOutcome?.rowId == record.row.rowId)
                #expect(record.descriptorOutcome?.fileId == record.row.fileId)
            }
            let targetRecord = try #require(aliases.first { $0.row.path == "AGENTS.md" })
            let targetOutcome = try #require(targetRecord.descriptorOutcome)
            if case .available = targetOutcome.availability {
                #expect(targetOutcome.path == "AGENTS.md")
            } else {
                Issue.record("The real materializer must produce an available AGENTS descriptor")
            }
            for record in aliases {
                print(
                    "GO21 row=\(record.row.path),rowId=\(record.row.rowId),fileId=\(record.row.fileId ?? "none"),outcomePath=\(record.descriptorOutcome?.path ?? "none"),outcomeRow=\(record.descriptorOutcome?.rowId ?? "none")"
                )
            }
            do {
                _ = try BridgeProductFileViewBatchFactory.sealSnapshot(fixture.batchInput(snapshot: snapshot))
                #expect(await reconciler.builderFinished(attempt, outcome: .built) == .completed(attempt))
                successfulCycle = cycle
                sealedSnapshot = snapshot
                break
            } catch {
                let failure = BridgeFileSurfaceReconciler.failure(for: error, phase: .delivery)
                print("GO21 seal failed cycle=\(cycle): \(error);failure=\(failure),refresh=\(failure.refreshFailure)")
                Issue.record("Tracked symlink descriptor batch must seal (cycle \(cycle)): \(error)")
                nextAction = await reconciler.builderFailed(attempt, error: error, phase: .delivery)
                if cycle == 1 {
                    nextAction = await reconciler.retry()
                }
            }
        }
        #expect(successfulCycle == 1, "Tracked aliases must seal on the initial attempt; Retry is unnecessary")
        if let sealedSnapshot {
            do {
                try await fixture.verifyContentAndKeyIsolation(
                    snapshot: sealedSnapshot, source: source, subscriptionId: subscription.subscriptionId)
            } catch {
                await source.cancel(subscriptionId: subscription.subscriptionId)
                await construction.shutdown()
                await assertBridgeConstructionCoordinatorDrained(construction)
                admission.close()
                throw error
            }
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await construction.shutdown()
        await assertBridgeConstructionCoordinatorDrained(construction)
        admission.close()
    }
}

private struct SymlinkAliasGitFixture: Sendable {
    let rootURL: URL
    let worktree: Worktree
    let trackedPaths: Set<String> = ["AGENTS.md", "CLAUDE.md", "gemini.md"]
    let handle = "symlink-alias-file-view"
    let incarnation = UUIDv7.generate().uuidString

    var scope: BridgeProductJSONValue {
        .object([
            "kind": .string("file"), "changeFilter": .object(["kind": .string("none")]), "pathScope": .array([]),
            "interests": .array([
                .object([
                    "lane": .string("foreground"),
                    "paths": .array(trackedPaths.sorted().map(BridgeProductJSONValue.string)),
                ])
            ]),
        ])
    }

    static func make() async throws -> Self {
        let rootURL = try await FilesystemTestGitRepo.create(named: "go21-symlink-alias")
        try Data("shared agent instructions\n".utf8).write(to: rootURL.appending(path: "AGENTS.md"))
        for path in ["CLAUDE.md", "gemini.md"] {
            try FileManager.default.createSymbolicLink(
                atPath: rootURL.appending(path: path).path, withDestinationPath: "AGENTS.md")
        }
        try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["add", "--", "AGENTS.md", "CLAUDE.md", "gemini.md"])
        try await FilesystemTestGitRepo.runGit(
            at: rootURL, args: ["commit", "-m", "Tracked agent instruction aliases"])
        let tracked = try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["ls-files", "--stage"])
        print("GO21 tracked fixture: \(tracked)")
        return Self(
            rootURL: rootURL,
            worktree: Worktree(
                id: UUIDv7.generate(), repoId: UUIDv7.generate(), name: "symlink alias fixture", path: rootURL))
    }

    func contentRequest(
        descriptor: BridgeProductFileContentDescriptor,
        overrideDescriptorId: String? = nil
    ) throws -> BridgeProductFileContentRequest {
        var descriptorObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        if let overrideDescriptorId { descriptorObject["descriptorId"] = overrideDescriptorId }
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductContentRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "contentKind": "file.content", "contentRequestId": UUIDv7.generate().uuidString,
                "descriptor": descriptorObject, "kind": "content.open", "leaseId": UUIDv7.generate().uuidString,
                "operationCorrelationId": NSNull(), "paneSessionId": UUIDv7.generate().uuidString,
                "wireVersion": BridgeProductWireContract.version, "workerDerivationEpoch": 1,
                "workerInstanceId": UUIDv7.generate().uuidString,
            ]))
        guard case .fileContent(let fileRequest) = request else {
            throw ProductFileSourceFixtureError.invalidContentRequest
        }
        return fileRequest
    }

    func verifyContentAndKeyIsolation(
        snapshot: BridgeWorktreeFileKeyedSnapshot,
        source: BridgePaneProductFileMetadataSource,
        subscriptionId: String
    ) async throws {
        let context = try #require(await source.contextBySubscriptionId[subscriptionId])
        let records = snapshot.records.filter { trackedPaths.contains($0.row.path) }
        try await verifyIssuedReads(records: records, source: source, productAdmission: context.productAdmission)
        try await verifyTargetInvalidation(records: records, source: source, context: context)
        let alias = try #require(records.first { $0.row.path == "CLAUDE.md" })
        try await verifyAliasContainment(record: alias, source: source, context: context)
    }

    private func verifyIssuedReads(
        records: [BridgeWorktreeFileKeyedRecord],
        source: BridgePaneProductFileMetadataSource,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        for record in records {
            let outcome = try #require(record.descriptorOutcome)
            guard case .available(let descriptor) = outcome.availability else {
                Issue.record("Every tracked alias must have its own available descriptor")
                continue
            }
            let request = try contentRequest(descriptor: descriptor)
            let plan = try #require(await source.contentReadPlan(for: request, productAdmission: productAdmission))
            #expect(plan.relativePath == record.row.path)
            #expect(try await readBytes(plan) == Data("shared agent instructions\n".utf8))
            let forged = try contentRequest(descriptor: descriptor, overrideDescriptorId: UUIDv7.generate().uuidString)
            #expect(await source.contentReadPlan(for: forged, productAdmission: productAdmission) == nil)
        }
    }

    private func verifyTargetInvalidation(
        records: [BridgeWorktreeFileKeyedRecord],
        source: BridgePaneProductFileMetadataSource,
        context: BridgePaneProductFileMetadataSource.SubscriptionContext
    ) async throws {
        let productAdmission = context.productAdmission
        let index = context.manifestIndex
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let target = try #require(records.first { $0.row.path == "AGENTS.md" })
        let targetOutcome = try #require(target.descriptorOutcome)
        let alias = try #require(records.first { $0.row.path == "CLAUDE.md" })
        let aliasOutcome = try #require(alias.descriptorOutcome)
        let retained = try #require(
            await index.retainCurrentDescriptor(for: target.key, productAdmission: productAdmission))
        let targetAttempt = try #require(
            await index.reserveDescriptorAttempt(
                for: target.row.path, source: context.productSource, memberIncarnation: "default", interestRevision: 2,
                productAdmission: productAdmission, foregroundWorkAdmission: foreground))
        let aliasAttempt = try #require(
            await index.reserveDescriptorAttempt(
                for: alias.row.path, source: context.productSource, memberIncarnation: "default", interestRevision: 2,
                productAdmission: productAdmission, foregroundWorkAdmission: foreground))
        #expect(await index.invalidateDescriptor(for: target.row.path, productAdmission: productAdmission))
        let invalidated = await index.captureKeyedSnapshot()
        #expect(invalidated.records.first { $0.key == target.key }?.descriptorOutcome == nil)
        #expect(
            invalidated.records.filter { trackedPaths.contains($0.row.path) && $0.key != target.key }
                == records.filter { $0.key != target.key })
        #expect(!(await index.acceptDescriptorOutcome(targetOutcome, for: targetAttempt)))
        #expect(await index.acceptDescriptorOutcome(aliasOutcome, for: aliasAttempt))
        #expect(
            await index.issuedDescriptorOutcome(matching: retained.descriptor, productAdmission: productAdmission)
                == targetOutcome)
        let retainedRequest = try contentRequest(descriptor: retained.descriptor)
        let retainedPlan = try #require(
            await source.contentReadPlan(for: retainedRequest, productAdmission: productAdmission))
        #expect(try await readBytes(retainedPlan) == Data("shared agent instructions\n".utf8))
        let replacementBytes = Data("updated target instructions with a new content identity\n".utf8)
        try replacementBytes.write(to: rootURL.appending(path: target.row.path))
        let replacement = try await BridgePaneProductFileContentSource.materialize(
            .init(
                relativePath: target.row.path, rootURL: rootURL, row: target.row, source: context.productSource))
        let replacementAttempt = try #require(
            await index.reserveDescriptorAttempt(
                for: target.row.path, source: context.productSource, memberIncarnation: "default", interestRevision: 3,
                productAdmission: productAdmission, foregroundWorkAdmission: foreground))
        #expect(await index.acceptDescriptorOutcome(replacement.payload, for: replacementAttempt))
        #expect(
            await index.issuedDescriptorOutcome(matching: retained.descriptor, productAdmission: productAdmission)
                == targetOutcome)
        guard case .available(let replacementDescriptor) = replacement.payload.availability else {
            Issue.record("Changed target must issue its new descriptor")
            await index.releaseRetainedDescriptor(retained)
            return
        }
        #expect(replacementDescriptor != retained.descriptor)
        let replacementRequest = try contentRequest(descriptor: replacementDescriptor)
        let replacementPlan = try #require(
            await source.contentReadPlan(for: replacementRequest, productAdmission: productAdmission))
        #expect(try await readBytes(replacementPlan) == replacementBytes)
        do {
            let reader = try await BridgePaneProductFileContentSource.openReadSession(retainedPlan)
            await reader.close()
            Issue.record("Retained target descriptor must reject changed content")
        } catch BridgePaneProductFileContentSourceError.sourceChanged {
            // Exact issued identity remains retained, but content changed.
        }
        await index.releaseRetainedDescriptor(retained)
        #expect(await index.retainedDescriptorLeaseCount == 0)
        #expect(
            await index.issuedDescriptorOutcome(matching: retained.descriptor, productAdmission: productAdmission)
                == targetOutcome)
        let refreshed = await index.captureKeyedSnapshot()
        #expect(
            refreshed.records.filter { trackedPaths.contains($0.row.path) && $0.key != target.key }
                == records.filter { $0.key != target.key })
        _ = try BridgeProductFileViewBatchFactory.sealSnapshot(batchInput(snapshot: refreshed))

    }

    private func verifyAliasContainment(
        record: BridgeWorktreeFileKeyedRecord,
        source: BridgePaneProductFileMetadataSource,
        context: BridgePaneProductFileMetadataSource.SubscriptionContext
    ) async throws {
        let productAdmission = context.productAdmission
        let alias = record
        let aliasOutcome = try #require(alias.descriptorOutcome)
        // An issued alias stays path-bound; retargeting it outside the root
        // cannot turn an issued descriptor into outside-file read authority.
        guard case .available(let aliasDescriptor) = aliasOutcome.availability else {
            Issue.record("Alias must issue a descriptor")
            return
        }
        let aliasRequest = try contentRequest(descriptor: aliasDescriptor)
        let aliasPlan = try #require(
            await source.contentReadPlan(for: aliasRequest, productAdmission: productAdmission))
        let outsideRoot = try await FilesystemTestGitRepo.create(named: "go21-outside-alias-target")
        defer { FilesystemTestGitRepo.destroy(outsideRoot) }
        let outsideFile = outsideRoot.appending(path: "instructions.md")
        try Data("shared agent instructions\n".utf8).write(to: outsideFile)
        try FileManager.default.removeItem(at: rootURL.appending(path: alias.row.path))
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: alias.row.path), withDestinationURL: outsideFile)
        await #expect(throws: BridgeSourcePathContainmentError.outsideRoot) {
            let reader = try await BridgePaneProductFileContentSource.openReadSession(aliasPlan)
            await reader.close()
        }
        let outsideMaterialization = try await BridgePaneProductFileContentSource.materialize(
            .init(
                relativePath: alias.row.path, rootURL: rootURL, row: alias.row, source: context.productSource))
        #expect(outsideMaterialization.payload.availability == .unavailable(.outsideScope))
    }

    private func readBytes(_ plan: BridgePaneProductFileContentReadPlan) async throws -> Data {
        let reader = try await BridgePaneProductFileContentSource.openReadSession(plan)
        do {
            var bytes = Data()
            while let chunk = try await reader.nextChunk(
                maximumByteCount: BridgeProductWireContract.maximumContentDataPayloadBytes)
            {
                bytes.append(chunk)
            }
            await reader.close()
            return bytes
        } catch {
            await reader.close()
            throw error
        }
    }

    func sourceSpec() throws -> BridgeProductFileSourceSpec {
        try BridgeProductStrictJSON.decode(
            BridgeProductFileSourceSpec.self,
            from: JSONSerialization.data(withJSONObject: [
                "cwdScope": NSNull(), "freshness": "live", "includeStatuses": false,
                "repoId": worktree.repoId.uuidString, "rootPathToken": StableKey.fromPath(rootURL),
                "worktreeId": worktree.id.uuidString,
            ]))
    }

    func demand() throws -> BridgePaneProductFileViewDemand {
        .init(
            admissionSequence: 1, handle: handle, scopeRevision: 1,
            state: try BridgeProductViewScopeContract.fileDemand(from: scope))
    }

    func batchInput(snapshot: BridgeWorktreeFileKeyedSnapshot) -> BridgeProductFileViewSnapshotInput {
        .init(
            viewDomain: .init(viewId: "symlink-file-metadata", domain: .singleDomain, incarnation: incarnation),
            handle: handle, scopeRevision: 1, scope: scope, firstDeliverySequence: 1, snapshot: snapshot)
    }
}
