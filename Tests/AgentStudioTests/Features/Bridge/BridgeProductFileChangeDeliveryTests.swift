import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File certificate and following change delivery")
struct BridgeProductFileChangeDeliveryTests {
    @Test("a capture held before N3 sealing cannot cross a changed path scope")
    func sealedCaptureCannotCrossScope() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        let capturedScope = try #require(
            await harness.session.acceptedViewScope(
                subscriptionId: fixture.subscriptionId))
        let capturedInventory = try fixture.snapshot(target: 2, complete: true, changedRowRevision: 2)
        let beforeSeal = HeldStep<BridgeProductAcceptedViewScopeSnapshot>("Old File capture before N3 seal admission")
        defer { beforeSeal.release() }
        let oldCapture = Task {
            try await beforeSeal.arrive(capturedScope)
            return try await harness.session.sealFileCapture(
                subscriptionId: fixture.subscriptionId, snapshot: capturedInventory,
                scope: capturedScope,
                productAdmission: harness.productAdmission.context)
        }
        #expect(try await beforeSeal.firstArrival().revision == 1)
        let replacement = try fixture.scopeRequest(revision: 2, paths: ["file-1.swift"])
        #expect(
            await harness.session.acceptViewScope(
                replacement, productAdmission: harness.productAdmission.context) == nil)
        beforeSeal.release()
        #expect(try await oldCapture.value == false)
        #expect(await harness.session.viewSenderState.hasActiveEmission(for: fixture.domain) == false)
        try await harness.closeProducer(fixture.lease)
    }

    @Test("queued certificate keeps the emission waiter pending after credit-held coverage completes")
    func pendingCertificateKeepsWaiter() async throws {
        let registrations = LocalFactSource<String, BridgeProductViewDomainKey>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { $0.viewId }, isClosing: { _, _ in false }))
        let recorder = try registrations.attach()
        let sink = registrations.sink
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { sink("File", $0) })
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: false))
        // Begin and eight parts fill the real part-credit window; coverage cannot finish yet.
        for _ in 0..<9 { _ = try await fixture.nextFrame() }
        try await fixture.seal(fixture.snapshot(target: 2, complete: true))
        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(for: fixture.domain, handle: fixture.handle)
        }
        _ = try await recorder.expectNext(in: "File", where: { $0 == fixture.domain }, "File emission waiter")
        try await fixture.acknowledge(through: 8)
        for _ in 0..<3 { _ = try await fixture.nextFrame() }
        #expect(await harness.session.pendingFileSnapshotByViewDomain[fixture.domain]?.targetRevision == 2)
        #expect(await harness.session.viewEmissionWaiterByDomain[fixture.domain] != nil)
        // Pumping the certificate, rather than finishing coverage, releases the waiter.
        let frames = try await fixture.consumeBatch(partCount: 10)
        #expect(frames.first?.kind == "subscription.batchBegin")
        if case .batch(.begin(let begin)) = frames.first {
            #expect(begin.snapshotCause == .open)
        }
        #expect(await waiting.value == .completed)
        #expect(await harness.session.pendingFileSnapshotByViewDomain[fixture.domain] == nil)
        registrations.end()
        try await recorder.finish()
        try await harness.closeProducer(fixture.lease)
    }

    @Test("a File refresh after the certificate sends only dirty revisions at the certificate base")
    func changeUsesLastSealedTarget() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        try await fixture.seal(fixture.snapshot(target: 3, complete: true, changedRowRevision: 3))
        let beginFrame = try await fixture.nextFrame()
        guard case .batch(.begin(let begin)) = beginFrame else {
            Issue.record("Expected File refresh batch begin")
            try await harness.closeProducer(fixture.lease)
            return
        }
        #expect(begin.mode == .change)
        #expect(begin.baseRevision == 1)
        #expect(begin.targetRevision == 3)
        #expect(begin.partCount == 1)
        // Consume the actual declared batch even on red; cleanup never depends on the desired count.
        for _ in 0..<begin.partCount {
            let frame = try await fixture.nextFrame()
            if case .batch(.part(let part)) = frame {
                if begin.mode == .change {
                    if case .put(_, let revision, _) = part.part {
                        #expect(revision > begin.baseRevision)
                    } else if case .delete(_, let revision) = part.part {
                        #expect(revision > begin.baseRevision)
                    }
                }
                try await fixture.acknowledge(through: part.deliverySequence)
            }
        }
        #expect(try await fixture.nextFrame().kind == "subscription.batchComplete")
        try await harness.closeProducer(fixture.lease)
    }

    @Test(
        "explicit resnapshot and changed filter retain full-inventory certification",
        arguments: [false, true])
    func resnapshotAndFilterRemainFull(changeFilter: Bool) async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        if changeFilter {
            let request = try fixture.scopeRequest(revision: 2, paths: ["file-1.swift"])
            #expect(
                await harness.session.acceptViewScope(
                    request, productAdmission: harness.productAdmission.context) == nil)
        } else {
            let bytes = try JSONSerialization.data(
                withJSONObject: fixture.requestObject(
                    kind: "subscription.resnapshot", revision: 1))
            let request = try BridgeProductStrictJSON.decode(BridgeProductViewResnapshotRequest.self, from: bytes)
            #expect(
                await harness.session.acceptViewResnapshot(
                    request, productAdmission: harness.productAdmission.context) == nil)
        }
        try await fixture.seal(fixture.snapshot(target: 2, complete: true, changedRowRevision: 2))
        let frames = try await fixture.consumeBatch(partCount: 10)
        guard case .batch(.begin(let begin)) = frames.first else {
            Issue.record("Expected full File replacement batch")
            try await harness.closeProducer(fixture.lease)
            return
        }
        #expect(begin.mode == .snapshot)
        #expect(begin.snapshotCause == (changeFilter ? .open : .requested))
        #expect(begin.baseRevision == 0)
        #expect(begin.partCount == 10)
        try await harness.closeProducer(fixture.lease)
    }

    @Test("change revision selection includes newer status and deletions without replaying older revisions")
    func changeIncludesStatusAndTombstones() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        let inventory = try fixture.snapshot(target: 4, complete: true, changedRowRevision: 3)
        try await fixture.seal(
            .init(
                isEnumerationComplete: true,
                memberStatus: .init(record: inventory.memberStatus.record, revision: 4),
                records: inventory.records, targetRevision: 4,
                tombstoneRevisionByKey: ["/workspace/old-delete": 1, "/workspace/new-delete": 3],
                absenceFloorRevisionByRange: [:]))
        let beginFrame = try await fixture.nextFrame()
        guard case .batch(.begin(let begin)) = beginFrame else {
            Issue.record("Expected File change batch begin")
            try await harness.closeProducer(fixture.lease)
            return
        }
        #expect(begin.mode == .change)
        #expect(begin.baseRevision == 1)
        #expect(begin.partCount == 3)
        var changedKeys: [String] = []
        for _ in 0..<begin.partCount {
            let frame = try await fixture.nextFrame()
            if case .batch(.part(let part)) = frame {
                switch part.part {
                case .put(let key, let revision, _), .delete(let key, let revision):
                    changedKeys.append(key)
                    if begin.mode == .change { #expect(revision > begin.baseRevision) }
                case .evict(let key):
                    Issue.record("File change unexpectedly evicted \(key)")
                }
                try await fixture.acknowledge(through: part.deliverySequence)
            }
        }
        #expect(
            Set(changedKeys)
                == Set([
                    "/workspace/file-1.swift", "/workspace/new-delete", BridgeProductFileMemberStatusRecord.recordKey,
                ]))
        #expect(try await fixture.nextFrame().kind == "subscription.batchComplete")
        try await harness.closeProducer(fixture.lease)
    }

    @Test("a path-scope change during a sealed change replaces it with a full snapshot")
    func scopeChangeDuringDrainRequiresSnapshot() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        try await fixture.seal(fixture.snapshot(target: 2, complete: true, changedRowRevision: 2))
        let request = try fixture.scopeRequest(revision: 2, paths: ["file-1.swift"])
        #expect(
            await harness.session.acceptViewScope(
                request, productAdmission: harness.productAdmission.context) == nil)
        let inventory = try fixture.snapshot(target: 3, complete: true, changedRowRevision: 3)
        try await fixture.seal(
            .init(
                isEnumerationComplete: true, memberStatus: inventory.memberStatus,
                records: inventory.records.filter { $0.row.path == "file-1.swift" }, targetRevision: 3,
                tombstoneRevisionByKey: [:], absenceFloorRevisionByRange: [:]))
        let frames = try await fixture.consumeBatch(partCount: 2)
        guard case .batch(.begin(let begin)) = frames.first else {
            Issue.record("Expected File scope replacement begin")
            try await harness.closeProducer(fixture.lease)
            return
        }
        #expect(begin.mode == .snapshot)
        #expect(begin.baseRevision == 0)
        #expect(begin.identity.scopeRevision == 2)
        #expect(begin.targetRevision == 3)
        try await harness.closeProducer(fixture.lease)
    }
}

struct FileChangeDeliveryFixture: Sendable {
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let handle = "frozen-file-handle"
    let subscriptionId = "file-subscription-1"
    var domain: BridgeProductViewDomainKey {
        .init(viewId: subscriptionId, domain: .singleDomain, incarnation: "frozen-file-incarnation")
    }

    static func open(harness: BridgeProductSessionLifecycleHarness) async throws -> Self {
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2))
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
        let fixture = Self(harness: harness, lease: lease)
        let request = try fixture.scopeRequest(revision: 1, paths: [])
        #expect(
            await harness.session.acceptViewScope(
                request, productAdmission: harness.productAdmission.context) == nil)
        return fixture
    }

    func requestObject(kind: String, revision: Int) -> [String: Any] {
        [
            "kind": kind, "wireVersion": 2, "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1", "requestId": "\(kind)-\(revision)",
            "requestSequence": revision + 2, "subscriptionId": subscriptionId,
            "subscriptionKind": "file.metadata", "domain": "default", "handle": handle,
            "incarnation": domain.incarnation, "scopeRevision": revision,
        ]
    }

    func scopeRequest(revision: Int, paths: [String]) throws -> BridgeProductViewScopeRequest {
        var object = requestObject(kind: "subscription.setScope", revision: revision)
        object["scope"] = [
            "kind": "file", "changeFilter": ["kind": "none"], "interests": [], "pathScope": paths,
        ]
        return try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func snapshot(target: Int, complete: Bool, changedRowRevision: Int? = nil) throws -> BridgeWorktreeFileKeyedSnapshot
    {
        let source = try BridgeProductFileSourceIdentity(
            repoId: "00000000-0000-4000-8000-000000000001", rootRevisionToken: nil,
            sourceCursor: "frozen-cursor", sourceId: "frozen-source", subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002")
        return .init(
            isEnumerationComplete: complete, memberStatus: .init(record: .init(source: source), revision: 1),
            records: (1...9).map { ordinal in
                let path = "file-\(ordinal).swift"
                return .init(
                    key: "/workspace/\(path)", revision: ordinal == 1 ? changedRowRevision ?? 1 : 1,
                    row: .init(
                        rowId: "row-\(ordinal)", path: path, name: path, parentPath: nil, depth: 0,
                        isDirectory: false, fileId: "file-\(ordinal)", fileClass: .source,
                        sizeBytes: 1, lineCount: nil, changeStatus: nil), descriptorOutcome: nil)
            },
            targetRevision: target, tombstoneRevisionByKey: [:], absenceFloorRevisionByRange: [:])
    }

    func seal(_ snapshot: BridgeWorktreeFileKeyedSnapshot) async throws {
        try #require(
            try await harness.session.sealFileCapture(
                subscriptionId: subscriptionId, snapshot: snapshot,
                scope: try #require(await harness.session.acceptedViewScope(subscriptionId: subscriptionId)),
                productAdmission: harness.productAdmission.context))
    }

    func nextFrame() async throws -> BridgeProductMetadataFrame {
        let delivery = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
        return try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first)
    }

    func consumeBatch(partCount: Int) async throws -> [BridgeProductMetadataFrame] {
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(partCount + 2) {
            let frame = try await nextFrame()
            frames.append(frame)
            if case .batch(.part(let part)) = frame { try await acknowledge(through: part.deliverySequence) }
        }
        return frames
    }

    func acknowledge(through sequence: Int) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "kind": "subscription.acknowledge", "wireVersion": 2, "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1", "subscriptionId": subscriptionId,
            "domain": "default", "handle": handle, "incarnation": domain.incarnation,
            "receivedThroughDeliverySequence": sequence,
        ])
        let request = try BridgeProductStrictJSON.decode(BridgeProductViewAcknowledgementRequest.self, from: bytes)
        _ = try #require(
            await harness.session.acknowledgeViewReceipt(
                request, exactRequestBytes: bytes, productAdmission: harness.productAdmission.context))
    }
}
