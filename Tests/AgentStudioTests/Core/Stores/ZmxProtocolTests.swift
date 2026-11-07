import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Bundled zmx protocol")
struct ZmxProtocolTests {
    @Test("the control client's protocol matches the bundled daemon")
    func bundledProtocolMatchesControlClient() throws {
        // The independent oracle is the vendor's declaration, not an app fixture.
        let source = try String(contentsOfFile: "vendor/zmx/src/ipc.zig", encoding: .utf8)
        let declaration = try #require(
            source.split(separator: "\n").first { $0.hasPrefix("pub const PROTOCOL_VERSION: u8 = ") })
        let literal = try #require(declaration.split(separator: "=").last)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let vendorVersion = try #require(UInt8(literal))

        #expect(ZmxProtocol.version == vendorVersion)
    }
}
