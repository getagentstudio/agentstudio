import Foundation

package struct IPCWindowRenderParams: Codable, Equatable, Sendable {
    package let workspaceWindowId: UUID

    package init(workspaceWindowId: UUID) {
        self.workspaceWindowId = workspaceWindowId
    }
}

package struct IPCWindowContentSize: Codable, Equatable, Sendable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

package struct IPCWindowRenderedImage: Codable, Equatable, Sendable {
    package let path: String
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let scale: Double
    package let imagePointSize: IPCWindowContentSize

    package init(path: String, pixelWidth: Int, pixelHeight: Int, scale: Double, imagePointSize: IPCWindowContentSize) {
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.imagePointSize = imagePointSize
    }
}

package struct IPCWindowRenderResult: Codable, Equatable, Sendable {
    package let workspaceWindowId: UUID
    package let image: IPCWindowRenderedImage
    package let contentSize: IPCWindowContentSize

    package init(workspaceWindowId: UUID, image: IPCWindowRenderedImage, contentSize: IPCWindowContentSize) {
        self.workspaceWindowId = workspaceWindowId
        self.image = image
        self.contentSize = contentSize
    }
}

package struct IPCWindowResizeParams: Codable, Equatable, Sendable {
    package let workspaceWindowId: UUID
    package let contentWidth: Double
    package let contentHeight: Double
    package let correlationId: UUID

    package init(workspaceWindowId: UUID, contentWidth: Double, contentHeight: Double, correlationId: UUID) {
        self.workspaceWindowId = workspaceWindowId
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.correlationId = correlationId
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceWindowId = try container.decode(UUID.self, forKey: .workspaceWindowId)
        contentWidth = try container.decode(Double.self, forKey: .contentWidth)
        contentHeight = try container.decode(Double.self, forKey: .contentHeight)
        correlationId = try container.decode(UUID.self, forKey: .correlationId)
        guard contentWidth.isFinite, contentHeight.isFinite, contentWidth > 0, contentHeight > 0 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath, debugDescription: "Content dimensions must be finite and positive"))
        }
    }
}

package struct IPCWindowResizeResult: Codable, Equatable, Sendable {
    package let workspaceWindowId: UUID
    package let contentSize: IPCWindowContentSize
    package let correlationId: UUID

    package init(workspaceWindowId: UUID, contentSize: IPCWindowContentSize, correlationId: UUID) {
        self.workspaceWindowId = workspaceWindowId
        self.contentSize = contentSize
        self.correlationId = correlationId
    }
}
