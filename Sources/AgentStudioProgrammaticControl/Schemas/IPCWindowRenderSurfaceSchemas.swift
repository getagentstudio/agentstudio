import Foundation

extension IPCWindowSurfaceFrame: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "x", description: "Visible left edge in image points", schema: .number(minimum: 0)),
            .init(name: "y", description: "Visible top edge in image points", schema: .number(minimum: 0)),
            .init(name: "width", description: "Visible width in points", schema: .number(minimum: 0)),
            .init(name: "height", description: "Visible height in points", schema: .number(minimum: 0)),
        ])
    }
}

extension IPCWindowRenderSurface: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "kind", description: "Captured region kind",
                schema: .string(allowedValues: IPCWindowRenderSurfaceKind.allCases.map(\.rawValue))),
            .init(
                name: "paneId", description: "Unambiguous owning pane", schema: IPCSchemaScalars.uuid,
                presence: .optional),
            .init(
                name: "identifier", description: "Bridge identifier or length-prefixed bound sidebar row identity",
                schema: .string(), presence: .optional),
            .init(
                name: "frame", description: "Visible intersection in PNG top-left points",
                schema: try IPCWindowSurfaceFrame.ipcSchema()),
            .init(
                name: "clipped", description: "The original region extends beyond its visible intersection",
                schema: .boolean),
        ])
    }
}
