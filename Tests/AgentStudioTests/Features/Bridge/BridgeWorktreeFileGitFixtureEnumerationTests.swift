import AgentStudioCore
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File enumeration of the real viewer Git fixture")
struct BridgeWorktreeFileGitFixtureEnumerationTests {
    @Test("the real source seals coverage, certificate, descriptor and resnapshot batches", arguments: [false, true])
    func viewerSourcePublishes(selectAfterCertificate: Bool) async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let delivery = try await FileChangeDeliveryFixture.open(harness: harness)
        let fixture = try ProductFileSourceFixture(fileCount: 0, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        try await seedViewerGitTree(at: fixture.rootURL)
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let source = fixture.makeSource(constructionCoordinator: coordinator)
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(
            foregroundPaths: selectAfterCertificate ? [] : ["zz-large-complete-file.txt"], handle: delivery.handle)
        let recording = ViewerFileBatchRecording()
        let context = ViewerFileBatchContext(
            source: source, subscription: subscription, demand: demand,
            admission: harness.productAdmission.context, delivery: delivery, recording: recording)
        do {
            try await source.open(subscription: subscription, productAdmission: harness.productAdmission.context) { _ in
                try await source.applyViewDemand(
                    subscriptionId: subscription.subscriptionId, demand: demand,
                    productAdmission: harness.productAdmission.context, forceRecapture: false
                ) { _ in }
                try await context.captureAndRecord()
            }
            let selectionRevision = selectAfterCertificate ? 2 : 1
            if selectAfterCertificate {
                var object = delivery.requestObject(kind: "subscription.setScope", revision: selectionRevision)
                object["scope"] = [
                    "kind": "file", "changeFilter": ["kind": "none"], "pathScope": [],
                    "interests": [["lane": "foreground", "paths": ["zz-large-complete-file.txt"]]],
                ]
                let selection = try BridgeProductStrictJSON.decode(
                    BridgeProductViewScopeRequest.self,
                    from: JSONSerialization.data(withJSONObject: object))
                #expect(
                    await harness.session.acceptViewScope(
                        selection,
                        productAdmission: harness.productAdmission.context) == nil)
            }
            let selectedDemand = try fixture.viewDemand(
                foregroundPaths: ["zz-large-complete-file.txt"],
                scopeRevision: selectionRevision, handle: delivery.handle)
            let selectedContext = ViewerFileBatchContext(
                source: source, subscription: subscription,
                demand: selectedDemand, admission: harness.productAdmission.context, delivery: delivery,
                recording: recording)
            try await source.applyViewDemand(
                subscriptionId: subscription.subscriptionId, demand: selectedDemand,
                productAdmission: harness.productAdmission.context, forceRecapture: true
            ) { _ in try await selectedContext.captureAndRecord() }
            let batches = await recording.batches
            let certificate = try #require(batches.first { $0.begin.mode == .snapshot })
            #expect(try certificate.rows.count == 51)
            let enrichment = try #require(batches.first { $0.begin.mode == .change })
            try assertProductFileDescriptorChange(
                enrichment, certificate: certificate, demandedPath: "zz-large-complete-file.txt")
            let request = try BridgeProductStrictJSON.decode(
                BridgeProductViewResnapshotRequest.self,
                from: JSONSerialization.data(
                    withJSONObject: delivery.requestObject(
                        kind: "subscription.resnapshot", revision: selectionRevision)))
            #expect(
                await harness.session.acceptViewResnapshot(
                    request, productAdmission: harness.productAdmission.context) == nil)
            try await selectedContext.captureAndRecord()
            #expect(await recording.batches.last?.begin.mode == .snapshot)
        } catch {
            Issue.record("Viewer source/N3 delivery failed: \(error)")
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        try await harness.closeProducer(delivery.lease)
    }

    @Test("the viewer tree reaches a certified inventory", arguments: [false, true])
    func viewerTreeCompletes(useManifest: Bool) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 0)
        defer { fixture.remove() }
        try await seedViewerGitTree(at: fixture.rootURL)
        let policy = await loadTestBridgeFileIgnorePolicy(rootURL: fixture.rootURL)
        #expect(policy.publishableFilePaths?.count == 43)
        let worktree = Worktree(id: fixture.worktreeId, repoId: fixture.repoId, name: "viewer", path: fixture.rootURL)
        let spec = BridgeWorktreeFileSurfaceSourceSpec(
            clientRequestId: "viewer-enumeration", repoId: fixture.repoId, worktreeId: fixture.worktreeId,
            rootPathToken: worktree.stableKey, cwdScope: nil, pathScope: [],
            includeStatuses: true, includeComments: false, includeAgentComms: false, freshness: .live)
        let opened = try BridgeWorktreeFileSourceProvider.openSource(
            spec: spec, worktree: worktree, subscriptionGeneration: 1)
        let selectedPolicy =
            useManifest
            ? policy
            : BridgeWorktreeFileIgnorePolicy(
                filesystemPathFilter: FilesystemPathFilter.load(forRootPath: fixture.rootURL),
                publishableFilePaths: nil)
        let request = BridgeWorktreeFileMaterializationRequest(
            rootURL: fixture.rootURL, openedSource: opened.withIgnorePolicy(selectedPolicy))
        var windows: [BridgeWorktreeTreeRowWindowBatch] = []
        do {
            for try await window in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
                request: request, afterCount: 0, windowSize: 8)
            {
                windows.append(window)
            }
        } catch {
            Issue.record("Valid viewer tree enumeration failed: \(error)")
        }
        #expect(windows.last?.isFinalWindow == true)
        let rows = windows.flatMap(\.rows)
        #expect(rows.count == 51)
        #expect(Set(rows.map(\.path)).count == 51)
        #expect(rows.filter { !$0.isDirectory }.count == 43)
        #expect(rows.contains { $0.path == "zz-large-complete-file.txt" })
        #expect(!rows.contains { $0.path == ".git" || $0.path.hasPrefix(".git/") })
    }
}

private actor ViewerFileBatchRecording {
    private(set) var batches: [ProductFileDescriptorBatchObservation] = []
    func append(_ batch: ProductFileDescriptorBatchObservation) { batches.append(batch) }
}

private struct ViewerFileBatchContext: Sendable {
    let source: BridgePaneProductFileMetadataSource
    let subscription: BridgeProductSubscriptionSnapshot
    let demand: BridgePaneProductFileViewDemand
    let admission: BridgeProductAdmissionContext
    let delivery: FileChangeDeliveryFixture
    let recording: ViewerFileBatchRecording

    func captureAndRecord() async throws {
        let snapshot = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand, productAdmission: admission))
        let scope = try #require(
            await delivery.harness.session.acceptedViewScope(
                subscriptionId: subscription.subscriptionId))
        // Descriptor reconciliation may report a no-op before its changed capture.
        guard
            try await delivery.harness.session.sealFileCapture(
                subscriptionId: subscription.subscriptionId, snapshot: snapshot,
                scope: scope, productAdmission: admission)
        else { return }
        guard case .batch(.begin(let begin)) = try await delivery.nextFrame() else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        var parts: [BridgeProductBatchPart] = []
        for _ in 0..<begin.partCount {
            guard case .batch(.part(let part)) = try await delivery.nextFrame() else {
                throw ProductFileSourceFixtureError.invalidControlRequest
            }
            parts.append(part.part)
            try await delivery.acknowledge(through: part.deliverySequence)
        }
        guard case .batch(.complete(let complete)) = try await delivery.nextFrame() else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        #expect(complete.identity.batchId == begin.identity.batchId)
        let batch = ProductFileDescriptorBatchObservation(begin: begin, parts: parts)
        await recording.append(batch)
    }
}

private func seedViewerGitTree(at rootURL: URL) async throws {
    var contentsByPath: [String: String] = [
        "fixture-proof.md": "# BRIDGE_VITE_PRODUCT_MARKDOWN_PAINT_PROOF\n",
        "fixture-proof.swift":
            "public enum BridgeViteProductCodeProof {\n    public static let marker = \"BRIDGE_VITE_PRODUCT_CODE_PAINT_MARKER\"\n}\n",
        "zz-large-complete-file.txt": (0..<128).map { index in
            switch index {
            case 0: "BRIDGE_VITE_PRODUCT_FIRST_BYTE_MARKER"
            case 63: "BRIDGE_VITE_PRODUCT_MIDDLE_BYTE_MARKER"
            case 127: "BRIDGE_VITE_PRODUCT_FINAL_BYTE_MARKER"
            default: String(format: "bridge-vite-product-line-%04d", index + 1)
            }
        }.joined(separator: "\n") + "\n",
    ]
    for index in 0..<16 {
        let path = String(format: "nested/group-%02d/file-%02d.ts", index / 6 + 1, index + 1)
        contentsByPath[path] = "export const fixtureValue\(index + 1) = 'base-\(index + 1)';\n"
    }
    for index in 0..<24 {
        let path = String(format: "tree-only/section-%02d/entry-%03d.txt", index / 8 + 1, index + 1)
        contentsByPath[path] = "unchanged-tree-entry-\(index + 1)\n"
    }
    for (path, contents) in contentsByPath {
        let fileURL = rootURL.appending(path: path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
    }
    try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["init"])
    try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["config", "user.name", "File fixture"])
    try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["config", "user.email", "file-fixture@example.invalid"])
    try await FilesystemTestGitRepo.runGit(at: rootURL, args: ["add", "."])
    try await FilesystemTestGitRepo.runGit(
        at: rootURL, args: ["-c", "commit.gpgsign=false", "commit", "-m", "Viewer fixture"])
    for index in 0..<16 {
        let path = String(format: "nested/group-%02d/file-%02d.ts", index / 6 + 1, index + 1)
        try Data("export const fixtureValue\(index + 1) = 'head-\(index + 1)';\n".utf8)
            .write(to: rootURL.appending(path: path))
    }
}
