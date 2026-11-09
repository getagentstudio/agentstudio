import AgentStudioInfrastructure
import Testing

@testable import AgentStudioCore

@Suite("Pane PR author keys")
struct PanePullRequestAuthorTests {
    @Test("Author keys round-trip opaque separators and Unicode and exclude binding generations")
    func authorKeyRoundTrip() throws {
        let pane = PaneId.generateUUIDv7()
        let conversation = BridgeAgentContributorIdentity(
            provider: try BridgeAgentProviderName("codex"), sessionRef: try BridgeAgentSessionRef("a:b/%雪"))
        let cases: [(PanePullRequestAuthor, String)] = [
            (.person, "person"),
            (.client(credentialKey: "diagnostic:a/b%"), "client:diagnostic%3Aa%2Fb%25"),
            (.paneAgent(sourcePaneId: pane, conversation: nil), "agent:\(pane.uuidString)"),
            (
                .paneAgent(sourcePaneId: pane, conversation: conversation),
                "agent:\(pane.uuidString):codex:a%3Ab%2F%25%E9%9B%AA"
            ),
        ]
        for (author, key) in cases {
            #expect(PanePullRequestAuthorKeyCodec.encode(author) == key)
            #expect(try PanePullRequestAuthorKeyCodec.decode(key) == author)
        }
    }

    @Test(arguments: ["", "app", "agent:bad", "client:", "client:%xx", "person:extra"])
    func malformedAuthorKeysAreRefused(key: String) {
        #expect(throws: (any Error).self) { try PanePullRequestAuthorKeyCodec.decode(key) }
    }
}
