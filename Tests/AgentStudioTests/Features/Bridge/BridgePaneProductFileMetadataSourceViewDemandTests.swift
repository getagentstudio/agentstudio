import AgentStudioCore
import AgentStudioInfrastructure
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File view demand")
struct BridgePaneProductFileMetadataSourceViewDemandTests {
    @Test("same-interest resnapshot re-reads changed File bytes without a changeset")
    func sameInterestResnapshotRecapturesChangedDescriptor() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        let opened = try fixture.openSnapshot()
        let interested = try fixture.viewDemand()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: interested,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        let before = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: interested,
                productAdmission: fixture.productAdmission.context
            ))
        try Data("replacement after stream loss\n".utf8).write(to: fixture.demandedFileURL)

        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: interested,
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: foreground.admission,
            forceRecapture: true
        ) { _ in }

        let after = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: interested,
                productAdmission: fixture.productAdmission.context
            ))
        let changedOutcome = try #require(after.records.compactMap(\.descriptorOutcome).first)
        guard case .available(let descriptor) = changedOutcome.availability else {
            Issue.record("Expected a readable descriptor after the same-interest recapture")
            return
        }
        #expect(after.targetRevision > before.targetRevision)
        #expect(descriptor.expectedSha256 == fileMetadataSourceSHA256Hex(Data("replacement after stream loss\n".utf8)))
    }

    @Test("initial File view scope demands the selected descriptor after source open")
    func initialViewScopeDemandsSelectedDescriptor() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let opened = try fixture.openSnapshot()
        let demand = try fixture.viewDemand()
        let collector = ProductFileSourceFactCollector()

        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await collector.append(event, source: source)
        }
        #expect((await collector.events).compactMap(\.availableDescriptorForTest).isEmpty)

        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: demand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }

        #expect(
            (await collector.events).contains {
                if case .descriptorReady(let ready) = $0 {
                    return ready.path == fixture.demandedPath
                }
                return false
            })
        #expect(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: demand,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
    }

    @Test("new File view scope selects its new path and fences a held old descriptor")
    func changedSelectedPathFencesHeldDescriptor() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 2)
        defer { fixture.remove() }
        let gate = ProductFileMaterializationGate()
        let heldPath = fixture.demandedPath
        let source = fixture.makeSource(descriptorMaterializer: { request in
            if request.relativePath == heldPath {
                await gate.markStarted()
                await gate.waitUntilReleased()
            }
            return try await BridgePaneProductFileContentSource.materialize(request)
        })
        let opened = try fixture.openSnapshot()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let staleDemand = try fixture.viewDemand()
        let latestDemand = try fixture.viewDemand(
            foregroundPaths: ["File-0001.swift"], scopeRevision: 2
        )
        let staleCollector = ProductFileSourceFactCollector()
        let latestCollector = ProductFileSourceFactCollector()
        let staleTask = Task {
            try await source.applyViewDemand(
                subscriptionId: opened.subscriptionId,
                demand: staleDemand,
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                await staleCollector.append(event, source: source)
            }
        }
        await gate.waitUntilStarted()

        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: latestDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await latestCollector.append(event, source: source)
        }
        await gate.release()
        try await staleTask.value

        #expect(
            (await latestCollector.events).contains {
                if case .descriptorReady(let ready) = $0 {
                    return ready.path == "File-0001.swift"
                }
                return false
            })
        #expect((await staleCollector.events).compactMap(\.availableDescriptorForTest).isEmpty)
        #expect(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: staleDemand,
                productAdmission: fixture.productAdmission.context
            ) == nil
        )
        #expect(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: latestDemand,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
    }

    @Test("File path scope changes certify only rows inside the accepted scope")
    func pathScopeProjectsTheCurrentKeyedIndex() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 2)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let opened = try fixture.openSnapshot()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let firstDemand = try fixture.viewDemand(
            foregroundPaths: [], pathScope: ["File-0000.swift"]
        )
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: firstDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        let firstSnapshot = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: firstDemand,
                productAdmission: fixture.productAdmission.context
            ))
        #expect(firstSnapshot.records.map(\.row.path) == ["File-0000.swift"])

        let secondDemand = try fixture.viewDemand(
            foregroundPaths: [], pathScope: ["File-0001.swift"], scopeRevision: 2
        )
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: secondDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        let secondSnapshot = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: secondDemand,
                productAdmission: fixture.productAdmission.context
            ))
        #expect(secondSnapshot.records.map(\.row.path) == ["File-0001.swift"])
        #expect(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: firstDemand,
                productAdmission: fixture.productAdmission.context
            ) == nil)
    }

    @Test("new File handle accepts a restarted scope revision and rejects the late old handle")
    func replacementHandleFencesLateOldScope() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 2)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let opened = try fixture.openSnapshot()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let originalDemand = try fixture.viewDemand(
            foregroundPaths: [], pathScope: ["File-0000.swift"], scopeRevision: 5,
            admissionSequence: 10, handle: "file-view-handle-original"
        )
        let replacementDemand = try fixture.viewDemand(
            foregroundPaths: [], pathScope: ["File-0001.swift"], scopeRevision: 0,
            admissionSequence: 11, handle: "file-view-handle-replacement"
        )
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: originalDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: replacementDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: originalDemand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }

        let current = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: replacementDemand,
                productAdmission: fixture.productAdmission.context
            ))
        #expect(current.records.map(\.row.path) == ["File-0001.swift"])
        #expect(
            await source.captureKeyedSnapshot(
                subscriptionId: opened.subscriptionId,
                demand: originalDemand,
                productAdmission: fixture.productAdmission.context
            ) == nil)
    }

    @Test("open streams bounded real tree windows and typed status")
    func openStreamsBoundedRealTreeWindowsAndStatus() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 260)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let snapshot = try fixture.openSnapshot()
        let collector = ProductFileSourceFactCollector()

        // Act
        try await source.open(
            subscription: snapshot,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await collector.append(event, source: source)
        }

        // Assert
        let events = await collector.events
        let windows = events.compactMap { event -> ProductFileInventoryObservation? in
            guard case .inventoryProgress(let window) = event else { return nil }
            return window
        }
        #expect(events.contains { if case .sourceAccepted = $0 { true } else { false } })
        #expect(windows.filter { !$0.rows.isEmpty }.count == 2)
        #expect(windows.count == 3)
        #expect(
            windows.allSatisfy {
                $0.rows.count <= BridgeProductWireContract.maximumFileMetadataTreeWindowRowCount
            })
        #expect(windows.last?.finalWindow == true)
        #expect(windows.last?.rows.isEmpty == true)
        #expect(windows.last?.inventoryRowCount == 260)
        #expect(windows.flatMap(\.rows).count == 260)
        #expect(windows.flatMap(\.rows).contains { $0.path == fixture.demandedPath })
        #expect(events.contains { if case .statusChanged = $0 { true } else { false } })
    }

    @Test("interest publishes exact complete metadata and a descriptor-bound read plan")
    func interestPublishesExactCompleteMetadataAndReadPlan() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1, demandedLineCount: 10_200)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let updatedSnapshot = try fixture.viewDemand()
        let collector = ProductFileSourceFactCollector()

        // Act
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }

        // Assert
        let descriptorPayload = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileDescriptorReadyPayload? in
                guard case .descriptorReady(let ready) = event else { return nil }
                return ready
            }.first
        )
        guard case .available(let descriptor) = descriptorPayload.availability else {
            Issue.record("Expected an available text descriptor")
            return
        }
        let request = try fixture.contentRequest(descriptor: descriptor)
        let readPlan = try #require(
            await source.contentReadPlan(
                for: request,
                productAdmission: fixture.productAdmission.context
            )
        )
        let expectedData = try Data(contentsOf: fixture.demandedFileURL)
        let expectedSHA256 = fileMetadataSourceSHA256Hex(expectedData)
        #expect(readPlan.descriptor == descriptor)
        #expect(readPlan.relativePath == fixture.demandedPath)
        #expect(readPlan.rootURL == fixture.rootURL)
        #expect(descriptor.declaredByteLength == expectedData.count)
        #expect(descriptor.expectedSha256 == expectedSHA256)
        #expect(descriptorPayload.encoding == .utf8)
        #expect(descriptorPayload.payloadByteCount == expectedData.count)
        #expect(descriptorPayload.payloadLineCount == 10_200)
        #expect(descriptorPayload.totalLineCount == 10_200)
        #expect(descriptorPayload.truncationKind == .complete)
        #expect(!descriptorPayload.endsMidLine)
        #expect(descriptorPayload.endsWithNewline)
        #expect(descriptorPayload.virtualizedExtentKind == .exactLineCount)
    }

    @Test("interest refresh upserts a non-first row without emitting a positional window")
    func interestRefreshUpsertsNonFirstRowWithoutRelocatingFirstRow() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 3, demandedIndex: 2)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        let openCollector = ProductFileSourceFactCollector()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await openCollector.append(event, source: source)
        }
        let initialRows = (await openCollector.events).flatMap(\.inventoryProgressRowsForTest)
        let initialFirstPath = try #require(initialRows.first?.path)
        let updateCollector = ProductFileSourceFactCollector()

        // Act
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: fixture.viewDemand(),
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await updateCollector.append(event, source: source)
        }

        // Assert
        let updateEvents = await updateCollector.events
        let upsertedRows = updateEvents.flatMap(\.inventoryChangedUpsertRowsForTest)
        #expect(initialFirstPath == "File-0000.swift")
        #expect(fixture.demandedPath == "File-0002.swift")
        #expect(updateEvents.allSatisfy { if case .inventoryProgress = $0 { false } else { true } })
        #expect(upsertedRows.map(\.path) == [fixture.demandedPath])
        #expect(!upsertedRows.contains { $0.path == initialFirstPath })
    }

    @Test("changeset invalidates the row while an issued descriptor rejects changed bytes")
    func changesetEmitsDeltaInvalidationAndRevokesStaleContent() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let updatedSnapshot = try fixture.viewDemand()
        let collector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }
        let descriptor = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileContentDescriptor? in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return nil }
                return descriptor
            }.first
        )
        let contentRequest = try fixture.contentRequest(descriptor: descriptor)
        #expect(
            await source.contentReadPlan(
                for: contentRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
        try Data("replacement\n".utf8).write(to: fixture.demandedFileURL)

        // Act
        let emissions = try await source.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: [fixture.demandedPath],
                timestamp: .now,
                batchSeq: 1
            ),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        #expect(emissions.contains { if case .inventoryChanged = $0.fact { true } else { false } })
        #expect(emissions.contains { if case .invalidated = $0.fact { true } else { false } })
        let retainedPlan = try #require(
            await source.contentReadPlan(
                for: contentRequest,
                productAdmission: fixture.productAdmission.context
            )
        )
        await #expect(throws: BridgePaneProductFileContentSourceError.self) {
            _ = try await BridgePaneProductFileContentSource.openReadSession(retainedPlan)
        }
    }
}
