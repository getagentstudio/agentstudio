import Foundation

enum PaneContextPixelContrast {
    @concurrent nonisolated static func measure(_ pixels: Data) async -> Int {
        guard pixels.count >= 4 else { return 0 }
        let background = Array(pixels.prefix(4))
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) { total, offset in
            total + (0..<4).reduce(0) { $0 + abs(Int(pixels[offset + $1]) - Int(background[$1])) }
        }
    }
}
