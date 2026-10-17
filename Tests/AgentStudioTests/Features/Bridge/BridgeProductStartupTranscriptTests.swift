import AgentStudioTestSupport
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product startup transcript")
struct BridgeProductStartupTranscriptTests {
    private static let validFixturePath =
        "Tests/BridgeContractFixtures/valid/bridge-product-startup-transcript.json"
    private static let invalidFixturePath =
        "Tests/BridgeContractFixtures/invalid/bridge-product-startup-transcript.json"
    private static let validMirrorPath =
        "BridgeWeb/src/test-fixtures/bridge-contract-fixtures/valid/bridge-product-startup-transcript.json"
    private static let invalidMirrorPath =
        "BridgeWeb/src/test-fixtures/bridge-contract-fixtures/invalid/bridge-product-startup-transcript.json"
    private static let validFixtureSHA256 =
        "29ddcc6601f7b531f637cf9a3c57a1dbdeee6dcc9e60087218ea951c7edc4498"
    private static let invalidFixtureSHA256 =
        "e51803d06d8dafd56d6c694569ed238bb3dd8bddadfec6d26b2834b5d5892a68"

    @Test("Swift source fixtures and TypeScript mirrors have frozen byte identity")
    func fixturesHaveFrozenByteIdentity() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let fixturePairs = [
            (Self.validFixturePath, Self.validMirrorPath, Self.validFixtureSHA256),
            (Self.invalidFixturePath, Self.invalidMirrorPath, Self.invalidFixtureSHA256),
        ]

        // Act
        let identities = try fixturePairs.map { sourcePath, mirrorPath, expectedSHA256 in
            let sourceBytes = try Data(contentsOf: projectRoot.appending(path: sourcePath))
            let mirrorBytes = try Data(contentsOf: projectRoot.appending(path: mirrorPath))
            return (sourceBytes, mirrorBytes, expectedSHA256, sha256Hex(sourceBytes))
        }

        // Assert
        for (sourceBytes, mirrorBytes, expectedSHA256, observedSHA256) in identities {
            #expect(sourceBytes == mirrorBytes)
            #expect(observedSHA256 == expectedSHA256)
        }
    }

    @Test("already-supported startup and event structures decode and round-trip")
    func supportedTranscriptStructuresDecodeAndRoundTrip() throws {
        // Arrange
        let fixture = try loadFixture(relativePath: Self.validFixturePath)
        let transcript = try fixtureArray(named: "transcript", in: fixture)

        // Act / Assert
        #expect(transcript.count == 21)
        for entry in transcript {
            let codec = try #require(entry["codec"] as? String)
            let name = try #require(entry["name"] as? String)
            let value = try #require(entry["value"] as? [String: Any])
            do {
                switch codec {
                case "contentHeader":
                    try assertRoundTrip(BridgeProductContentHeader.self, object: value, name: name)
                case "contentRequest":
                    try assertRoundTrip(BridgeProductContentRequest.self, object: value, name: name)
                case "controlRequest":
                    try assertRoundTrip(BridgeProductControlRequest.self, object: value, name: name)
                case "controlResponse":
                    try assertRoundTrip(BridgeProductControlResponse.self, object: value, name: name)
                case "metadataFrame":
                    try assertRoundTrip(BridgeProductMetadataFrame.self, object: value, name: name)
                case "metadataStreamRequest":
                    try assertRoundTrip(
                        BridgeProductMetadataStreamRequest.self,
                        object: value,
                        name: name
                    )
                default:
                    Issue.record("Unsupported startup transcript codec: \(codec)")
                }
            } catch {
                Issue.record("Startup transcript entry \(name) failed \(codec) decoding: \(error)")
            }
        }
    }

    @Test("Review subscription lifecycle retains E3 identity without an interest hash")
    func reviewSubscriptionLifecycleRetainsIdentity() throws {
        // Arrange
        let fixture = try loadFixture(relativePath: Self.validFixturePath)
        let openCommand = try decodeTranscriptValue(
            BridgeProductControlRequest.self,
            named: "review-subscription-open",
            in: fixture
        )
        let openResponse = try decodeTranscriptValue(
            BridgeProductControlResponse.self,
            named: "review-subscription-open-accepted",
            in: fixture
        )
        let acceptedFrame = try decodeTranscriptValue(
            BridgeProductMetadataFrame.self,
            named: "review-subscription-accepted-frame",
            in: fixture
        )
        let cancelledFrame = try decodeTranscriptValue(
            BridgeProductMetadataFrame.self,
            named: "review-subscription-cancelled-frame",
            in: fixture
        )
        guard case .subscriptionOpen(let opened) = openCommand,
            case .subscriptionOpenAccepted(let acceptedResponse) = openResponse,
            case .subscriptionAccepted(let accepted) = acceptedFrame,
            case .subscriptionCancelled(let cancelled) = cancelledFrame
        else {
            Issue.record("Review startup transcript does not contain its E3 lifecycle")
            return
        }

        // Assert
        #expect(acceptedResponse.subscriptionId == opened.subscriptionId)
        #expect(acceptedResponse.subscriptionKind == opened.subscription.subscriptionKind)
        #expect(acceptedResponse.worktreeId == nil)
        #expect(accepted.subscriptionIdentity.subscriptionId == opened.subscriptionId)
        #expect(cancelled.identity.subscriptionIdentity.subscriptionId == opened.subscriptionId)
        #expect(accepted.subscriptionIdentity.workerDerivationEpoch == opened.workerDerivationEpoch)
        #expect(cancelled.identity.subscriptionIdentity.workerDerivationEpoch == opened.workerDerivationEpoch)
    }

    @Test("retired metadata observation is rejected by the command package")
    func retiredMetadataObservationIsRejected() throws {
        // Arrange
        let fixture = try loadFixture(relativePath: Self.invalidFixturePath)
        let observationCases = try fixtureArray(named: "cases", in: fixture)
        let metadataCase = try #require(
            observationCases.first { observationCase in
                (observationCase["request"] as? [String: Any])?["streamKind"] as? String
                    == "metadata"
            }
        )
        let request = try #require(metadataCase["request"] as? [String: Any])

        // Act
        #expect(throws: (any Error).self) {
            _ = try decodeCommandPackage(request)
        }
    }

    @Test("content accepted data and end cumulative credits decode through the command package")
    func contentCumulativeCreditsDecodeThroughCommandPackage() throws {
        // Arrange
        let fixture = try loadFixture(relativePath: Self.validFixturePath)
        let observationCases = try fixtureArray(named: "observationCases", in: fixture)
        let requiredCaseNames = [
            "content-accepted-sequence-zero",
            "content-data-sequence-one",
            "content-end-sequence-two",
        ]

        // Act
        let requiredCases = try requiredCaseNames.map { requiredName in
            try #require(
                observationCases.first { $0["name"] as? String == requiredName },
                "Missing required content credit \(requiredName)"
            )
        }

        // Assert
        for requiredCase in requiredCases {
            let name = try #require(requiredCase["name"] as? String)
            let request = try #require(requiredCase["request"] as? [String: Any])
            let package = try decodeCommandPackage(request)
            guard case .contentFrameAcknowledgement = package else {
                Issue.record("\(name) did not decode as a cumulative content acknowledgement")
                continue
            }
        }
    }

    @Test("structurally hostile observation bodies are rejected")
    func structurallyHostileObservationBodiesAreRejected() throws {
        // Arrange
        let fixture = try loadFixture(relativePath: Self.invalidFixturePath)
        let invalidCases = try fixtureArray(named: "cases", in: fixture)

        // Act
        let acceptedCases = invalidCases.compactMap { fixtureCase -> String? in
            guard
                let name = fixtureCase["name"] as? String,
                let request = fixtureCase["request"] as? [String: Any]
            else { return "malformed-fixture-case" }
            return (try? decodeCommandPackage(request)) == nil ? nil : name
        }

        // Assert
        #expect(invalidCases.count == 10)
        #expect(acceptedCases.isEmpty)
    }

    private func loadFixture(relativePath: String) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let bytes = try Data(contentsOf: projectRoot.appending(path: relativePath))
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func fixtureArray(
        named name: String,
        in fixture: [String: Any]
    ) throws -> [[String: Any]] {
        try #require(fixture[name] as? [[String: Any]])
    }

    private func assertRoundTrip<CodableValue: Codable>(
        _ type: CodableValue.Type,
        object: [String: Any],
        name: String
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try BridgeProductStrictJSON.decode(type, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(encodedObject.isEqual(to: object), Comment(rawValue: name))
    }

    private func decodeTranscriptValue<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        named name: String,
        in fixture: [String: Any]
    ) throws -> DecodedValue {
        let transcript = try fixtureArray(named: "transcript", in: fixture)
        let entry = try #require(transcript.first { $0["name"] as? String == name })
        let value = try #require(entry["value"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(type, from: data)
    }

    private func decodeCommandPackage(
        _ object: [String: Any]
    ) throws -> BridgeProductCommandPackage {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(BridgeProductCommandPackage.self, from: data)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
