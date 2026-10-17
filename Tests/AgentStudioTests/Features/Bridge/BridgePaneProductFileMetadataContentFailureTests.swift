import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileMetadataSourceTests {
    @Test("a file removed between enumeration and read becomes typed unreadable metadata")
    func removedFileBecomesTypedUnreadableMetadata() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let collector = ProductFileSourceFactCollector()
        try await source.open(
            subscription: fixture.openSnapshot(),
            productAdmission: fixture.productAdmission.context
        ) { event in
            await collector.append(event, source: source)
        }
        let row = try #require((await collector.events).flatMap(\.inventoryProgressRowsForTest).first)
        let productSource = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileSourceIdentity? in
                guard case .sourceAccepted(let accepted) = event else { return nil }
                return accepted
            }.first
        )
        try FileManager.default.removeItem(at: fixture.demandedFileURL)

        // Act
        let materialization = try await BridgePaneProductFileContentSource.materialize(
            .init(
                relativePath: row.path,
                rootURL: fixture.rootURL,
                row: BridgeWorktreeTreeRowMetadata(
                    rowId: row.rowId,
                    path: row.path,
                    name: row.name,
                    parentPath: row.parentPath,
                    depth: row.depth,
                    isDirectory: row.isDirectory,
                    fileId: row.fileId,
                    fileClass: row.fileClass,
                    sizeBytes: row.sizeBytes,
                    lineCount: row.lineCount,
                    changeStatus: row.changeStatus?.rawValue
                ),
                source: productSource
            )
        )

        // Assert
        #expect(materialization.payload.virtualizedExtentKind == .unavailable)
        #expect(materialization.payload.payloadByteCount == 0)
        guard case .unavailable(let reason) = materialization.payload.availability else {
            Issue.record("Expected typed unavailable metadata")
            return
        }
        #expect(reason == .unreadable)
    }
}

extension BridgeProductContentFrame {
    var isTerminalForTest: Bool {
        switch header {
        case .end, .error, .reset: true
        case .accepted, .data: false
        }
    }
}
