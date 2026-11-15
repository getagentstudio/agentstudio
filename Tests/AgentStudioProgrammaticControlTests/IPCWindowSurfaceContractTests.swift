import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Window surface wire contract")
struct IPCWindowSurfaceContractTests {
    @Test("all eight crop kinds round-trip with closed geometry and optional identity")
    func windowSurfaceSchemaPreservesCropContract() throws {
        let schema = try IPCWindowRenderSurface.ipcSchema()
        let paneId = UUIDv7.generate()
        for kind in [
            "sidebar", "tabContent", "paneLeaf", "paneToolbar", "paneCard", "toolbarControl", "agentLine", "sidebarRow",
        ] {
            let object: [String: Any] = [
                "kind": kind, "paneId": paneId.uuidString, "identifier": "repeated-control",
                "frame": ["x": 12.5, "y": 30, "width": 100, "height": 20], "clipped": true,
            ]
            let value = try schema.decode(
                IPCWindowRenderSurface.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(value.kind.rawValue == kind && value.paneId == paneId && value.clipped)
            #expect(value.frame == .init(x: 12.5, y: 30, width: 100, height: 20))
            #expect(try schema.decode(IPCWindowRenderSurface.self, from: JSONEncoder().encode(value)) == value)
        }
        let minimal: [String: Any] = [
            "kind": "toolbarControl", "frame": ["x": 0, "y": 0, "width": 5, "height": 5], "clipped": false,
        ]
        let value = try schema.decode(
            IPCWindowRenderSurface.self, from: JSONSerialization.data(withJSONObject: minimal))
        #expect(value.paneId == nil && value.identifier == nil)
        for (field, invalid): (String, Any) in [("kind", "invented"), ("paneId", "invalid"), ("extra", true)] {
            var object = minimal
            object[field] = invalid
            #expect(throws: IPCSchemaValidationError.self) {
                try schema.normalize(JSONSerialization.data(withJSONObject: object))
            }
        }
        var negative = minimal
        negative["frame"] = ["x": -1, "y": 0, "width": 5, "height": 5]
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(JSONSerialization.data(withJSONObject: negative))
        }
        let resultSchema = try IPCWindowRenderResult.ipcSchema()
        let result = IPCWindowRenderResult(
            workspaceWindowId: UUIDv7.generate(),
            image: .init(
                path: "/fixture/frame.png", pixelWidth: 100, pixelHeight: 100, scale: 2,
                imagePointSize: .init(width: 50, height: 50)),
            contentSize: .init(width: 50, height: 50), surfaces: [value])
        let encoded = try JSONEncoder().encode(result)
        #expect(try resultSchema.decode(IPCWindowRenderResult.self, from: encoded) == result)
        var missing = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        missing.removeValue(forKey: "surfaces")
        #expect(throws: IPCSchemaValidationError.self) {
            try resultSchema.normalize(JSONSerialization.data(withJSONObject: missing))
        }
    }
}
