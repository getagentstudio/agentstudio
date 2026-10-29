import AppKit
import Foundation
import Testing

/// Caches cannot include native vibrancy; composite native pixels over the declared opaque shell token.
@MainActor
func paneContextOpaqueFramePNG(_ bitmap: NSBitmapImageRep, background: NSColor) throws -> Data {
    let canvas = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    background.setFill()
    NSBezierPath(rect: bounds).fill()
    try #require(
        bitmap.draw(
            in: bounds, from: CGRect(origin: .zero, size: bitmap.size), operation: .sourceOver,
            fraction: 1, respectFlipped: false, hints: nil),
        "The actual native cached pixels did not draw onto their opaque canvas")
    context.flushGraphics()
    try #require(
        canvas.colorAt(x: 0, y: 0)?.alphaComponent == 1,
        "Frame capture must have an opaque background before PNG export")
    return try #require(canvas.representation(using: .png, properties: [:]))
}
