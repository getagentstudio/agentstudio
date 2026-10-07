import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC result schemas")
struct IPCResultSchemaTests {
    @Test("nested optional result values round-trip through the declared schema")
    func nestedOptionalResultRoundTrip() throws {
        let paneId = UUIDv7.generate()
        let tabId = UUIDv7.generate()
        let workspaceId = UUIDv7.generate()
        let result = IPCPaneSnapshotResult(
            pane: IPCPaneSummary(
                id: paneId,
                ordinal: 2,
                contentKind: .terminal,
                residency: .active,
                tabId: tabId,
                repoId: nil,
                worktreeId: nil,
                isActive: true,
                isDrawerChild: false
            ),
            tab: IPCQueryFixture.tab(id: tabId, paneId: paneId),
            workspace: IPCQueryFixture.workspace(id: workspaceId)
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try IPCPaneSnapshotResult.ipcSchema().decode(
            IPCPaneSnapshotResult.self,
            from: encoded
        )

        #expect(decoded == result)
    }

    @Test(
        "pane activity is a closed source with Foundation wall time or explicit null",
        arguments: [
            IPCPaneActivity?.none,
            .some(.init(at: Date(timeIntervalSinceReferenceDate: 12_345.5), source: .hook)),
            .some(.init(at: Date(timeIntervalSinceReferenceDate: 12_345.5), source: .terminal)),
        ])
    func paneActivityRoundTrips(activity: IPCPaneActivity?) throws {
        let pane = IPCPaneSummary(
            id: UUIDv7.generate(), ordinal: 1, contentKind: .terminal, residency: .active,
            tabId: nil, repoId: nil, worktreeId: nil, isActive: true, isDrawerChild: false, activity: activity)
        let data = try JSONEncoder().encode(pane)
        #expect(try IPCPaneSummary.ipcSchema().decode(IPCPaneSummary.self, from: data) == pane)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
        if let activity {
            let encoded = try #require(object["activity"] as? [String: NSObject])
            #expect(Set(encoded.keys) == ["at", "source"])
            #expect((encoded["at"] as? NSNumber)?.doubleValue == activity.at.timeIntervalSinceReferenceDate)
            #expect(encoded["source"] as? String == activity.source.rawValue)
        } else {
            #expect(object["activity"] is NSNull)
        }
        let invalid = Data(#"{"at":12345.5,"source":"other"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPCPaneActivity.self, from: invalid) }
        #expect(throws: IPCSchemaValidationError.self) { try IPCPaneActivity.ipcSchema().normalize(invalid) }
    }

    @Test("result schemas reject fields synthesized Codable would ignore")
    func resultSchemaRejectsIgnoredFields() throws {
        let paneId = UUIDv7.generate()
        let json = Data(
            "{\"paneId\":\"\(paneId.uuidString)\",\"focused\":true,\"ignored\":1}".utf8
        )

        do {
            _ = try IPCPaneFocusResult.ipcSchema().decode(IPCPaneFocusResult.self, from: json)
            Issue.record("Expected the undeclared field to be rejected")
        } catch let failure as IPCSchemaValidationError {
            #expect(failure.reason == .unknownField)
            #expect(failure.fieldPath == "$")
        }
    }

    @Test("custom comparison variants expose their exact tagged wire keys")
    func comparisonVariantRoundTrip() throws {
        let target = IPCBridgeReviewComparisonTarget.originDefaultBranch(
            remoteName: "origin",
            branchName: "main",
            basis: .commonCommit
        )
        let encoded = try JSONEncoder().encode(target)
        let decoded = try IPCBridgeReviewComparisonTarget.ipcSchema().decode(
            IPCBridgeReviewComparisonTarget.self,
            from: encoded
        )
        #expect(decoded == target)

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCBridgeReviewComparisonTarget.ipcSchema().normalize(
                Data(
                    #"{"kind":"commit","oid":"0123456789012345678901234567890123456789","basis":"branchTip"}"#.utf8
                )
            )
        }
    }

    @Test("event payload alternatives reject mixed nested payloads")
    func eventPayloadAlternativesRejectMixedPayloads() throws {
        let paneId = UUIDv7.generate()
        let payload = IPCEventPayload.bridge(
            IPCBridgeEventPayload(paneId: paneId, itemId: "Sources/App.swift")
        )
        #expect(
            try IPCEventPayload.ipcSchema().decode(
                IPCEventPayload.self,
                from: JSONEncoder().encode(payload)
            ) == payload
        )

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCEventPayload.ipcSchema().normalize(
                Data(
                    "{\"kind\":\"bridge\",\"bridge\":{\"paneId\":\"\(paneId.uuidString)\"},\"terminal\":null}".utf8
                )
            )
        }
    }

    @Test("event envelopes preserve Foundation reference-date seconds")
    func eventEnvelopeDateWireRepresentation() throws {
        let occurredAt = Date(timeIntervalSinceReferenceDate: 1234.5)
        let notification = IPCEventNotification(
            eventId: UUIDv7.generate(),
            name: .bridgeContentReady,
            occurredAt: occurredAt,
            payload: .bridge(
                IPCBridgeEventPayload(paneId: UUIDv7.generate(), contentHandleId: "content-1")
            )
        )

        let encoded = try JSONEncoder().encode(notification)
        let decoded = try IPCEventNotification.ipcSchema().decode(
            IPCEventNotification.self,
            from: encoded
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(decoded == notification)
        #expect(object["occurredAt"] as? Double == 1234.5)
    }
}

private enum IPCQueryFixture {
    static func tab(id: UUID, paneId: UUID) -> IPCTabSummary {
        IPCTabSummary(
            id: id,
            ordinal: 1,
            name: "Main",
            paneIds: [paneId],
            activePaneId: paneId,
            isActive: true
        )
    }

    static func workspace(id: UUID) -> IPCWorkspaceSummary {
        IPCWorkspaceSummary(
            id: id,
            ordinal: 1,
            name: "Workspace",
            tabCount: 1,
            paneCount: 1,
            repositories: [],
            isCurrent: true
        )
    }
}
