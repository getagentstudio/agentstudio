import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Pane PR wire contracts")
struct IPCPanePullRequestContractTests {
    @Test("Mutation schema rejects an extra author and list is read-only for any authenticated target")
    func authorCannotBeSupplied() throws {
        let catalog = try IPCBuiltInMethodCatalog(inputs: IPCBuiltInMethodCatalogTestFixture.makeInputs())
        let descriptor = catalog.panePullRequests.add
        let parameters = descriptor.examples[0].parameters
        let forged = Data(
            """
            {"targetPaneHandle":"\(parameters.targetPaneHandle)","pullRequest":{"host":"github.com","owner":"owner","repository":"repo","number":7},"correlationId":"\(parameters.correlationId.uuidString)","author":{"kind":"person"}}
            """.utf8)
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(from: forged)
        }
        #expect(catalog.panePullRequests.list.requiredPrivileges == [.paneContextRead])
        #expect(catalog.panePullRequests.list.agentEligibility == .anyTarget)
        #expect(!catalog.panePullRequests.list.isMutating)
    }
}
