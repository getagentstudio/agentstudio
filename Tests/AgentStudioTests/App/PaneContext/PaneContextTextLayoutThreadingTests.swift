import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import CoreText
import Foundation
import SwiftUI
import Synchronization
import Testing

private enum TextLayoutFontStyle: Sendable { case regular, monospaced }

private enum TextLayoutSample: Sendable {
    case explicitLines(fontStyle: TextLayoutFontStyle, effectiveWidth: CGFloat)
    case wrappedMonospacedToken(effectiveWidth: CGFloat)

    var fontStyle: TextLayoutFontStyle {
        switch self {
        case .explicitLines(let style, _): style
        case .wrappedMonospacedToken: .monospaced
        }
    }

    var effectiveWidth: CGFloat {
        switch self {
        case .explicitLines(_, let width), .wrappedMonospacedToken(let width): width
        }
    }

    var body: String {
        switch self {
        case .explicitLines:
            Array(repeating: "error: cannot find 'value' in scope", count: 33).joined(separator: "\n")
        case .wrappedMonospacedToken: String(repeating: "W", count: 700) + "\nEnd"
        }
    }
}

private struct TextLayoutObservation: Sendable {
    let visualLines: Int
    let ranOnMainThread: Bool
    let requestedFont: String
    let storedFont: String
    let pointSize: Double
    let glyphAdvance: Double
    let containerWidth: Double
    let lineGlyphCounts: [Int]
    let lineWidths: [Double]
    let concurrentGraphsAtEntry: Int
}

@MainActor
@Suite("Pane context text layout threading", .serialized)
struct PaneContextTextLayoutThreadingTests {
    private nonisolated static let activeGraphs = Mutex(0)
    private nonisolated static let samples: [TextLayoutSample] = [
        .explicitLines(fontStyle: .regular, effectiveWidth: 320),
        .explicitLines(fontStyle: .regular, effectiveWidth: 478),
        .explicitLines(fontStyle: .monospaced, effectiveWidth: 320),
        .explicitLines(fontStyle: .monospaced, effectiveWidth: 478),
        .wrappedMonospacedToken(effectiveWidth: 320),
        .wrappedMonospacedToken(effectiveWidth: 478),
    ]

    @Test("F1 a private text-system graph counts known lines away from MainActor", arguments: samples)
    private func backgroundLayoutCountsKnownLines(sample: TextLayoutSample) async throws {
        let expectedLines = try Self.expectedVisualLines(for: sample)
        let applicationInitialized = NSApp != nil
        let observation = await Self.observeLayout(sample, context: EnvironmentValues().fontResolutionContext)
        print(
            "TEXT_LAYOUT_OBSERVATION", String(describing: sample), "expected", expectedLines,
            "actual", observation.visualLines, "requestedFont", observation.requestedFont,
            "storedFont", observation.storedFont, "pointSize", observation.pointSize,
            "glyphAdvance", observation.glyphAdvance, "containerWidth", observation.containerWidth,
            "glyphCounts", observation.lineGlyphCounts, "lineWidths", observation.lineWidths,
            "concurrentGraphsAtEntry", observation.concurrentGraphsAtEntry,
            "applicationInitialized", applicationInitialized)
        #expect(!observation.ranOnMainThread, "Text layout must execute on the worker, not the UI thread")
        let expectedPointSize =
            switch sample.fontStyle {
            case .regular: Double(AppStyles.General.Typography.textSm)
            case .monospaced: Double(AppStyles.General.Typography.textXs)
            }
        #expect(observation.pointSize == expectedPointSize, "The graph must receive the requested paint-font size")
        #expect(!observation.requestedFont.isEmpty, "The resolved paint font must have an identity before layout")
        #expect(
            observation.visualLines == expectedLines, "The visual-line oracle is independent of TextKit enumeration")
    }

    private static func expectedVisualLines(for sample: TextLayoutSample) throws -> Int {
        switch sample {
        case .explicitLines: return 33
        case .wrappedMonospacedToken:
            let glyphAdvance = ("W" as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: AppStyles.General.Typography.textXs, weight: .regular)
            ]).width
            let columns = Int(floor(sample.effectiveWidth / glyphAdvance))
            try #require(columns > 0)
            return Int(ceil(700.0 / Double(columns))) + 1
        }
    }

    @concurrent
    nonisolated
        private static func observeLayout(_ sample: TextLayoutSample, context: Font.Context) async
        -> TextLayoutObservation
    {
        let concurrentGraphs = activeGraphs.withLock { count in
            count += 1
            return count
        }
        defer { activeGraphs.withLock { $0 -= 1 } }
        return autoreleasepool {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let bodyFont: PaneContextMessageBodyFont
            switch sample.fontStyle {
            case .regular:
                bodyFont = .proportional(pointSize: AppStyles.General.Typography.textSm)
            case .monospaced:
                bodyFont = .monospaced(pointSize: AppStyles.General.Typography.textXs)
            }
            // Match the production worker's font source; keep glyph arithmetic independent on MainActor.
            let font = bodyFont.paintFont.resolve(in: context).ctFont as NSFont
            let requestedFontName = font.fontName
            let requestedPointSize = font.pointSize
            paragraph.lineSpacing = bodyFont.lineSpacing
            let storage = NSTextStorage(string: sample.body, attributes: [.font: font, .paragraphStyle: paragraph])
            let manager = NSLayoutManager()
            manager.backgroundLayoutEnabled = false
            let container = NSTextContainer(size: .init(width: sample.effectiveWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var visualLines = 0
            var counts: [Int] = []
            var widths: [Double] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, glyphs, _ in
                visualLines += 1
                counts.append(glyphs.length)
                widths.append(used.width)
            }
            var character: UniChar = 0x57
            var glyph = CGGlyph()
            CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
            let stored = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            return .init(
                visualLines: visualLines, ranOnMainThread: Thread.isMainThread,
                requestedFont: requestedFontName, storedFont: stored?.fontName ?? "missing",
                pointSize: requestedPointSize, glyphAdvance: advance.width, containerWidth: container.size.width,
                lineGlyphCounts: counts, lineWidths: widths, concurrentGraphsAtEntry: concurrentGraphs)
        }
    }
}
