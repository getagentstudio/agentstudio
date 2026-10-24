import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Darwin
import ImageIO
import Testing

@testable import AgentStudio

@MainActor
@Suite("Window content PNG rendering", .serialized)
struct WindowContentRendererTests {
    @Test(
        "finalized PNG preserves independently painted corners on ordinary and flipped content",
        arguments: [false, true])
    func windowRenderPreservesPaintedCorners(flipped: Bool) async throws {
        let fixture = try WindowRenderTestFixture(flipped: flipped)
        defer { fixture.tearDown() }

        let result = try await WindowContentRenderer.render(
            window: fixture.window, workspaceWindowId: fixture.windowId, rendersDirectory: fixture.rendersDirectory)
        let bitmap = try decodedWindowRenderBitmap(path: result.image.path)

        #expect(result.workspaceWindowId == fixture.windowId)
        #expect(result.contentSize == IPCWindowContentSize(width: 96, height: 64))
        #expect(result.image.imagePointSize == IPCWindowContentSize(width: 96, height: 64))
        #expect(result.image.pixelWidth == bitmap.pixelsWide)
        #expect(result.image.pixelHeight == bitmap.pixelsHigh)
        #expect(Double(bitmap.pixelsWide) == 96 * result.image.scale)
        #expect(Double(bitmap.pixelsHigh) == 64 * result.image.scale)
        try expectWindowRenderInk(bitmap, scale: result.image.scale)
        // Permissions are read from the actual finalized file and directory.
        #expect(try windowRenderMode(fixture.rendersDirectory) == 0o700)
        #expect(try windowRenderMode(URL(fileURLWithPath: result.image.path)) == 0o600)
    }

    @Test("render refuses a symlinked or nonprivate directory without creating an output", arguments: [false, true])
    func windowRenderRefusesUntrustedDirectory(symlinked: Bool) async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let destination = fixture.rootDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if symlinked {
            try FileManager.default.createSymbolicLink(at: fixture.rendersDirectory, withDestinationURL: destination)
        } else {
            try FileManager.default.createDirectory(at: fixture.rendersDirectory, withIntermediateDirectories: false)
            #expect(chmod(fixture.rendersDirectory.path, 0o755) == 0)
        }

        await #expect(throws: AppIPCWindowRenderError.untrustedRenderDirectory) {
            try await WindowContentRenderer.render(
                window: fixture.window, workspaceWindowId: fixture.windowId, rendersDirectory: fixture.rendersDirectory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rendersDirectory.path).isEmpty)
    }

    @Test("exclusive creation preserves existing files and refuses file symlinks", arguments: [false, true])
    func windowRenderCreatesFilesExclusively(symlinked: Bool) async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let renderId = UUIDv7.generate()
        try FileManager.default.createDirectory(
            at: fixture.rendersDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let existing = fixture.rendersDirectory.appendingPathComponent("\(renderId.uuidString).png")
        let protectedURL = symlinked ? fixture.rootDirectory.appendingPathComponent("protected") : existing
        let original = Data("retain this private evidence".utf8)
        try original.write(to: protectedURL)
        if symlinked { try FileManager.default.createSymbolicLink(at: existing, withDestinationURL: protectedURL) }
        let image = try fixture.image()

        await #expect(throws: AppIPCWindowRenderError.writeFailed) {
            try await WindowContentRenderer.writePNG(
                image: image, directory: fixture.rendersDirectory, renderId: renderId)
        }
        #expect(try Data(contentsOf: protectedURL) == original)
        #expect(FileManager.default.fileExists(atPath: existing.path))
    }

    @Test("a cancelled write removes its exclusive partial file before returning failure")
    func windowRenderRemovesPartialFileOnCancellation() async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let image = try fixture.image()
        let directory = fixture.rendersDirectory
        let renderId = UUIDv7.generate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WindowContentRenderer.writePNG(image: image, directory: directory, renderId: renderId)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@MainActor
struct WindowRenderTestFixture {
    let windowId = UUIDv7.generate()
    let rootDirectory: URL
    let window: NSWindow
    var rendersDirectory: URL { rootDirectory.appendingPathComponent("renders", isDirectory: true) }

    init(flipped: Bool = false) throws {
        _ = NSApplication.shared
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("arf-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: false)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 64),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = WindowRenderCornerInkView(flipped: flipped)
        window.setContentSize(NSSize(width: 96, height: 64))
    }

    func image() throws -> CGImage {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.cgImage)
    }

    func tearDown() {
        window.close()
        do { try FileManager.default.removeItem(at: rootDirectory) } catch {
            Issue.record(error, "Window render fixture cleanup failed")
        }
    }
}

@MainActor
private final class WindowRenderCornerInkView: NSView {
    let paintsFlippedCoordinates: Bool
    override var isFlipped: Bool { paintsFlippedCoordinates }

    init(flipped: Bool) {
        self.paintsFlippedCoordinates = flipped
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 64))
        let child = WindowRenderFlippedInkView(frame: NSRect(x: 36, y: 24, width: 24, height: 16))
        addSubview(child)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let topY: CGFloat = isFlipped ? 0 : 32
        let bottomY: CGFloat = isFlipped ? 32 : 0
        for (color, rect) in [
            (NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSRect(x: 0, y: topY, width: 48, height: 32)),
            (NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), NSRect(x: 48, y: topY, width: 48, height: 32)),
            (NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), NSRect(x: 0, y: bottomY, width: 48, height: 32)),
            (NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1), NSRect(x: 48, y: bottomY, width: 48, height: 32)),
        ] {
            color.setFill()
            rect.fill()
        }
    }
}

@MainActor
private final class WindowRenderFlippedInkView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 24, height: 8).fill()
        NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 8, width: 24, height: 8).fill()
    }
}

@MainActor
func decodedWindowRenderBitmap(path: String) throws -> NSBitmapImageRep {
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == 1)
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
}

func windowRenderMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}

@MainActor
func expectWindowRenderInk(_ bitmap: NSBitmapImageRep, scale: Double) throws {
    // Fixture paint, independently specified in top-left PNG point coordinates.
    let samples: [(Double, Double, [CGFloat])] = [
        (8, 8, [1, 0, 0]), (88, 8, [0, 1, 0]), (8, 56, [0, 0, 1]), (88, 56, [1, 1, 0]),
        (40, 28, [1, 0, 1]), (40, 36, [0, 1, 1]),
    ]
    for (pointX, pointY, expected) in samples {
        // The decoder has normalized the pixels to sRGB. Read those components directly:
        // colorAt wraps them in NSCalibratedRGBColorSpace; converting that wrapper reinterprets them.
        let actual = try #require(bitmap.colorAt(x: Int(pointX * scale), y: Int(pointY * scale)))
        #expect(abs(actual.redComponent - expected[0]) < 0.02)
        #expect(abs(actual.greenComponent - expected[1]) < 0.02)
        #expect(abs(actual.blueComponent - expected[2]) < 0.02)
        #expect(actual.alphaComponent > 0.98)
    }
}
