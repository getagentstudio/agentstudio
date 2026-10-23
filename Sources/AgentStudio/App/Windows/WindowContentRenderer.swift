import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum WindowContentRenderer {
    static func render(
        window: NSWindow, workspaceWindowId: UUID, rendersDirectory: URL
    ) async throws -> IPCWindowRenderResult {
        guard let contentView = window.contentView else { throw AppIPCWindowRenderError.noContentView }
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            throw AppIPCWindowRenderError.bitmapCreationFailed
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw AppIPCWindowRenderError.imageCreationFailed }
        let pointSize = bitmap.size
        guard pointSize.width > 0, pointSize.height > 0 else { throw AppIPCWindowRenderError.bitmapCreationFailed }
        let contentSize = IPCWindowContentSize(width: contentView.bounds.width, height: contentView.bounds.height)
        // The bitmap is never reused or mutated after extracting its immutable image.
        let path = try await writePNG(image: image, directory: rendersDirectory, renderId: UUIDv7.generate())
        return IPCWindowRenderResult(
            workspaceWindowId: workspaceWindowId,
            image: .init(
                path: path.path, pixelWidth: image.width, pixelHeight: image.height,
                scale: Double(image.width) / pointSize.width,
                imagePointSize: .init(width: pointSize.width, height: pointSize.height)),
            contentSize: contentSize)
    }

    @concurrent nonisolated static func writePNG(
        image: CGImage, directory: URL, renderId: UUID
    ) async throws -> URL {
        let directoryDescriptor = try openPrivateDirectory(directory)
        defer { _ = close(directoryDescriptor) }
        let filename = "\(renderId.uuidString).png"
        let fileDescriptor = openat(
            directoryDescriptor, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else { throw AppIPCWindowRenderError.writeFailed }
        var finalized = false
        defer {
            _ = close(fileDescriptor)
            if !finalized { _ = unlinkat(directoryDescriptor, filename, 0) }
        }
        guard fchmod(fileDescriptor, 0o600) == 0 else { throw AppIPCWindowRenderError.writeFailed }
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else {
            throw AppIPCWindowRenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppIPCWindowRenderError.encodingFailed }
        try writeAll(encoded as Data, descriptor: fileDescriptor)
        try Task.checkCancellation()
        guard fsync(fileDescriptor) == 0 else { throw AppIPCWindowRenderError.writeFailed }
        finalized = true
        return directory.appendingPathComponent(filename)
    }

    private nonisolated static func openPrivateDirectory(_ directory: URL) throws -> Int32 {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw AppIPCWindowRenderError.untrustedRenderDirectory
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AppIPCWindowRenderError.untrustedRenderDirectory }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_mode & 0o7777 == 0o700
        else {
            _ = close(descriptor)
            throw AppIPCWindowRenderError.untrustedRenderDirectory
        }
        return descriptor
    }

    private nonisolated static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { throw AppIPCWindowRenderError.encodingFailed }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw AppIPCWindowRenderError.writeFailed }
                offset += written
            }
        }
    }
}
