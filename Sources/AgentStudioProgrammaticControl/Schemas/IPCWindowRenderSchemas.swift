import Foundation

extension IPCWindowRenderParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [windowIdentityField()])
    }
}

extension IPCWindowContentSize: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "width", description: "Width in points", schema: .number(minimum: 0)),
            .init(name: "height", description: "Height in points", schema: .number(minimum: 0)),
        ])
    }
}

extension IPCWindowRenderedImage: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "path", description: "Finalized owner-only PNG path; caller owns cleanup", schema: .string()),
            .init(name: "pixelWidth", description: "Actual bitmap width in pixels", schema: .integer(minimum: 1)),
            .init(name: "pixelHeight", description: "Actual bitmap height in pixels", schema: .integer(minimum: 1)),
            .init(name: "scale", description: "Bitmap pixels per image point", schema: .number(minimum: 0)),
            .init(
                name: "imagePointSize", description: "Bitmap point size, with a top-left image origin",
                schema: try IPCWindowContentSize.ipcSchema()),
        ])
    }
}

extension IPCWindowRenderResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            windowIdentityField(),
            .init(name: "image", description: "Content-only PNG", schema: try IPCWindowRenderedImage.ipcSchema()),
            try windowContentSizeField(),
        ])
    }
}

extension IPCWindowResizeParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        // The typed decoder rejects zero as well. The schema algebra has inclusive bounds only.
        .object(fields: [
            windowIdentityField(),
            .init(
                name: "contentWidth", description: "Finite, strictly positive width in points",
                schema: .number(minimum: 0)),
            .init(
                name: "contentHeight", description: "Finite, strictly positive height in points",
                schema: .number(minimum: 0)),
            windowCorrelationField(),
        ])
    }
}

extension IPCWindowResizeResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [windowIdentityField(), try windowContentSizeField(), windowCorrelationField()])
    }
}

private func windowIdentityField() -> IPCObjectField {
    .init(name: "workspaceWindowId", description: "Explicit live workspace window UUID", schema: IPCSchemaScalars.uuid)
}

private func windowContentSizeField() throws -> IPCObjectField {
    .init(
        name: "contentSize", description: "Actual native content size after layout",
        schema: try IPCWindowContentSize.ipcSchema())
}

private func windowCorrelationField() -> IPCObjectField {
    .init(name: "correlationId", description: "Required caller correlation UUID", schema: IPCSchemaScalars.uuid)
}
