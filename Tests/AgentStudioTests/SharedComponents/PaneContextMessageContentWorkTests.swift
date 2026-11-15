import AgentStudioInfrastructure
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Bounded message content work", .serialized)
struct PaneContextMessageContentWorkTests {
    @Test("Notices never retain geometry needed only by an inline form")
    func noticeGeometryDoesNotWriteRowState() {
        var stored: PaneContextMessageBodyGeometry?
        var writes = 0
        let state = Binding(
            get: { stored },
            set: {
                stored = $0
                writes += 1
            })
        let capture = PaneContextMessageBodyGeometry(
            effectiveWidth: 408, fontContext: EnvironmentValues().fontResolutionContext)
        MessagePopoverRow.retainFormGeometry(capture, hasInlineForm: false, in: state)
        #expect(stored == nil)
        #expect(writes == 0)
    }

    @Test("Inline forms retain changed geometry and suppress equal writes")
    func inlineGeometryRetainsChangesOnly() {
        var stored: PaneContextMessageBodyGeometry?
        var writes = 0
        let state = Binding(
            get: { stored },
            set: {
                stored = $0
                writes += 1
            })
        let first = PaneContextMessageBodyGeometry(
            effectiveWidth: 408, fontContext: EnvironmentValues().fontResolutionContext)
        let next = PaneContextMessageBodyGeometry(effectiveWidth: 488, fontContext: first.fontContext)
        MessagePopoverRow.retainFormGeometry(first, hasInlineForm: true, in: state)
        MessagePopoverRow.retainFormGeometry(first, hasInlineForm: true, in: state)
        #expect(stored == first)
        #expect(writes == 1)
        MessagePopoverRow.retainFormGeometry(next, hasInlineForm: true, in: state)
        #expect(stored == next)
        #expect(writes == 2)
    }

    @Test("Canonical equality agrees with all 225 original attributed-paint pairs")
    func canonicalEqualityMatchesOriginalPaint() {
        let bodies = [
            "", "same prose", "different prose", "```swift\nlet value = 1\n```",
            "before\n```swift\nlet value = 1\n```\nafter",
        ]
        let fonts: [PaneContextMessageBodyFont] = [
            .proportional(pointSize: 12), .monospaced(pointSize: 12), .proportional(pointSize: 18),
        ]
        let values = bodies.flatMap { body in fonts.map { PaneContextMessageBodyText(body, font: $0) } }
        var pairs = 0
        for left in values {
            for right in values {
                let original =
                    left.plainText == right.plainText && left.paint == right.paint
                    && left.codeRanges == right.codeRanges
                #expect((left == right) == original)
                pairs += 1
            }
        }
        #expect(pairs == 225)
    }

    @Test("Pending paint is a bounded grapheme prefix with the original font spans")
    func pendingPaintIsBoundedAndPreservesSpans() {
        let font = PaneContextMessageBodyFont.proportional(pointSize: 12)
        let body = PaneContextMessageBodyText(
            "Résumé 👩🏽‍💻\n```swift\n" + String(repeating: "let value = 1\n", count: 50) + "```\nTail", font: font)
        let limit = 80
        let end = body.paint.characters.index(body.paint.startIndex, offsetBy: limit)
        let expected = AttributedString(body.paint[body.paint.startIndex..<end])
        let painted = PaneContextTruncatedMessageBody.paintText(
            fullText: body.paint, layout: .pendingWidth, geometry: nil, pendingLimit: limit)
        #expect(painted.characters.count == limit)
        #expect(painted == expected)
        #expect(painted.runs.contains { $0.font == PaneContextMessageBodyText.codeFont.paintFont })
        #expect(painted.runs.contains { $0.font == font.paintFont })
        #expect(body.plainText.hasSuffix("Tail"), "Bounding paint must not truncate canonical or accessibility content")
    }

    @Test("Matching prepared preview replaces pending paint exactly; stale geometry stays bounded")
    func preparedPreviewReplacesPendingPaintExactly() {
        let font = PaneContextMessageBodyFont.proportional(pointSize: 12)
        let full = PaneContextMessageBodyText(String(repeating: "Full original text ", count: 50), font: font).paint
        let preview = PaneContextMessageBodyText("Exact prepared preview…", font: font).paint
        let geometry = PaneContextMessageBodyGeometry(
            effectiveWidth: 408, fontContext: EnvironmentValues().fontResolutionContext)
        let layout = PaneContextMessageBodyLayout.ready(
            geometry: geometry, visualLines: 20, details: nil, preview: preview)
        #expect(
            PaneContextTruncatedMessageBody.paintText(
                fullText: full, layout: layout, geometry: geometry, pendingLimit: 5) == preview)
        let stale = PaneContextMessageBodyGeometry(effectiveWidth: 488, fontContext: geometry.fontContext)
        #expect(
            PaneContextTruncatedMessageBody.paintText(fullText: full, layout: layout, geometry: stale, pendingLimit: 5)
                .characters.count == 5)
        let short = PaneContextMessageBodyText("Short complete body", font: font).paint
        let uncollapsed = PaneContextMessageBodyLayout.ready(geometry: geometry, visualLines: 1, details: nil)
        #expect(
            PaneContextTruncatedMessageBody.paintText(
                fullText: short, layout: uncollapsed, geometry: geometry, pendingLimit: 5) == short)
    }

    @Test(
        "The pending budget covers collapsed lines of narrow printable glyphs at the current width",
        arguments: [CGFloat(320), 440, 560])
    func pendingBudgetCoversSupportedFonts(width: CGFloat) {
        let context = EnvironmentValues().fontResolutionContext
        let fonts: [PaneContextMessageBodyFont] = [
            .proportional(pointSize: 12), .monospaced(pointSize: 12), .proportional(pointSize: 18),
        ]
        for font in fonts {
            let native = font.paintFont.resolve(in: context).ctFont as NSFont
            let code = PaneContextMessageBodyText.codeFont.paintFont.resolve(in: context).ctFont as NSFont
            let advances = (32...126).flatMap { value -> [CGFloat] in
                let glyph = String(UnicodeScalar(value)!) as NSString
                return [
                    glyph.size(withAttributes: [.font: native]).width, glyph.size(withAttributes: [.font: code]).width,
                ]
            }.filter { $0 > 0 }
            let smallest = advances.min()!
            let sixLines = Int((width / smallest).rounded(.up)) * AppPolicies.PaneContext.collapsedMessageBodyLines
            #expect(font.pendingCharacterLimit(width: width) >= sixLines)
        }
        let bodyFont = PaneContextMessageBodyFont.proportional(pointSize: 12)
        #expect(
            bodyFont.pendingCharacterLimit(width: width) < 2107,
            "The captured long notices must not paint in full while pending")
    }

    @Test(
        "Unusable mount widths retain the supported-width pending budget",
        arguments: [CGFloat.zero, -1, .infinity, .nan])
    func unusableWidthsUsePendingFallback(width: CGFloat) {
        let font = PaneContextMessageBodyFont.proportional(pointSize: 12)
        let expected = font.pendingCharacterLimit(width: AppStyles.Components.PaneContext.messagesPopoverMaximumWidth)
        #expect(font.pendingCharacterLimit(width: width) == expected)
    }
}
