import AppKit
import Testing

@MainActor
enum PaneManagementIdentityTestInk {
    static func ink(
        in view: NSView, maximumX: Int?, bounds: CGRect? = nil
    ) throws -> (width: Int, height: Int, points: [Bool]) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let displayBounds = bounds ?? view.bounds
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: displayBounds))
        view.cacheDisplay(in: displayBounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let pixelsPerPoint = image.width / Int(displayBounds.width)
        let width = min(image.width, (maximumX ?? Int(displayBounds.width)) * pixelsPerPoint)
        var points: [Bool] = []
        for row in 0..<image.height {
            for column in 0..<width {
                let offset = (row * image.width + column) * 4
                points.append(max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2])) > 100)
            }
        }
        return (width, image.height, points)
    }

    static func contains(
        _ needle: (width: Int, height: Int, points: [Bool]),
        in haystack: (width: Int, height: Int, points: [Bool])
    ) -> Bool {
        let ink = needle.points.indices.filter { needle.points[$0] }.map {
            (x: $0 % needle.width, y: $0 / needle.width)
        }
        guard !ink.isEmpty, needle.width <= haystack.width, needle.height <= haystack.height else { return false }
        let minimumX = ink.map(\.x).min()!
        let maximumX = ink.map(\.x).max()!
        let minimumY = ink.map(\.y).min()!
        let maximumY = ink.map(\.y).max()!
        let width = maximumX - minimumX + 1
        let height = maximumY - minimumY + 1
        let allowedMisses = 0
        for originY in 0...(haystack.height - height) {
            for originX in 0...(haystack.width - width) {
                var misses = 0
                for row in 0..<height {
                    for column in 0..<width {
                        let expected = needle.points[(minimumY + row) * needle.width + minimumX + column]
                        let actual = haystack.points[(originY + row) * haystack.width + originX + column]
                        if expected != actual {
                            misses += 1
                            if misses > allowedMisses { break }
                        }
                    }
                    if misses > allowedMisses { break }
                }
                if misses <= allowedMisses { return true }
            }
        }
        return false
    }
}
