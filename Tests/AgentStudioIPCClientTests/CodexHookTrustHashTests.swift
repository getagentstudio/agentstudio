import AgentStudioIPCTransport
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Codex-owned trust hash vectors")
struct CodexHookTrustHashTests {
    struct Fixture: Decodable {
        let producer: String
        let command: String
        let cases: [Vector]
    }
    struct Vector: Decodable {
        let name: String
        let event: String
        let group: JSONValue
        let expectedHash: String
    }

    static func vectors() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "hook-hash-vectors", withExtension: "json", subdirectory: "Fixtures/codex-0.163"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("normalized identities match all literal hashes returned by Codex 0.163")
    func codexOwnedHashVectors() throws {
        let fixture = try Self.vectors()
        #expect(fixture.cases.count == 20)
        #expect(fixture.producer.contains("83086188ae0614bd882818ff1aa23f3194962012"))
        #expect(fixture.command.contains("hooks/list"))
        for vector in fixture.cases {
            let documentValue = JSONValue.object(["hooks": .object([vector.event: .array([vector.group])])])
            let document = try ProviderHookFileDocument(
                provider: .codex, data: JSONEncoder().encode(documentValue), path: "/scratch/hooks.json")
            let group = try #require(document.groupsByEvent[vector.event]?.first)
            guard case .command(let command)? = group.handlers.first else {
                Issue.record("vector command missing")
                continue
            }
            #expect(
                try CodexHookTrustHash.hash(event: vector.event, group: group, handler: command) == vector.expectedHash,
                "Codex vector: \(vector.name)")
        }
    }

    @Test("a correct SHA-256 without Codex normalization is rejected by the fixture")
    func wrongNormalizerSensitivity() throws {
        let fixture = try Self.vectors()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var mismatches: [String] = []
        for vector in fixture.cases {
            guard case .object(var fields) = vector.group else {
                Issue.record("invalid vector group")
                continue
            }
            fields["event_name"] = .string(CodexHookTrustHash.eventKey(vector.event))
            let hash =
                "sha256:"
                + SHA256.hash(data: try encoder.encode(JSONValue.object(fields))).map { String(format: "%02x", $0) }
                .joined()
            if hash != vector.expectedHash { mismatches.append(vector.name) }
        }
        #expect(mismatches.contains("default-timeout"))
        #expect(mismatches.contains("ignored-stop-matcher"))
        #expect(mismatches.contains("raw-session-end-async"))
    }

    @Test("review comparison uses Codex's literal current hash for every trust state")
    func reviewStatesUseProviderHash() throws {
        let vector = try #require(Self.vectors().cases.first)
        let hash = vector.expectedHash
        #expect(
            CodexHookReviewState(trustedHash: hash, enabled: true).problems(
                currentHash: hash, event: vector.event, key: "key"
            ).isEmpty)
        #expect(
            CodexHookReviewState(trustedHash: "sha256:stale", enabled: nil).problems(
                currentHash: hash, event: vector.event, key: "key") == [.codexModified(event: vector.event, key: "key")]
        )
        #expect(
            CodexHookReviewState().problems(currentHash: hash, event: vector.event, key: "key") == [
                .codexNeedsReview(event: vector.event, key: "key")
            ])
        #expect(
            CodexHookReviewState(trustedHash: hash, enabled: false).problems(
                currentHash: hash, event: vector.event, key: "key") == [.codexDisabled(event: vector.event, key: "key")]
        )
    }

    @Test("version qualification never guesses beyond the supported release window")
    func hashVersionWindow() {
        for version in ["0.154.0", "0.160.0", "0.163.0"] { #expect(CodexHookTrustHash.supports(version: version)) }
        for version in ["0.153.0", "0.164.0", "1.0.0", "unknown", "0.163.0-beta"] {
            #expect(!CodexHookTrustHash.supports(version: version))
        }
    }

    @Test("review keys and literal/inline state formats are read without writing")
    func reviewStateFormats() throws {
        let key = "/scratch/home/hooks.json:session_start:2:1"
        let hash = try #require(Self.vectors().cases.first?.expectedHash)
        let keyString = "\"\(key)\""
        let forms = [
            "[features]\nhooks = true\n[hooks.state.\(keyString)]\ntrusted_hash = \"\(hash)\"\nenabled = false\n",
            "[features]\nhooks = true\n[hooks.state]\n\(keyString) = { trusted_hash = '\(hash)', enabled = false } # owner comment\n",
            "features.hooks = true\nhooks.state.\(keyString).trusted_hash = \"\(hash)\"\nhooks.state.\(keyString).enabled = false\n",
        ]
        for text in forms {
            let document = try CodexHookReviewStateReader.read(text)
            #expect(document.hooksEnabled)
            #expect(document.states[key] == .init(trustedHash: hash, enabled: false))
        }
        #expect(
            CodexHookReviewStateReader.key(
                path: "/scratch/home/hooks.json", event: "SessionStart", group: 2, handler: 1) == key)
    }
}
