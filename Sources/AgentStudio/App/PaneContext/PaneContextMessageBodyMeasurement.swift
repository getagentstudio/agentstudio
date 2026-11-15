import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import CoreText
import Foundation
import SwiftUI
import Synchronization

/// Only scalar/value results survive the private TextKit graph's synchronous lifetime.
struct PaneContextMessageBodyMeasurement: Sendable, Equatable {
    struct Axis: Sendable, Hashable {
        let identifier: Int
        let value: Double
    }
    struct Feature: Sendable, Hashable {
        let type: Int
        let selector: Int
    }
    struct FontMetrics: Sendable, Hashable {
        let name: String
        let pointSize: Double
        let traits: UInt32
        let matrix: [Double]
        let variations: [Axis]
        let features: [Feature]
        let ascent: Double
        let descent: Double
        let leading: Double
        let lineSpacing: Double
    }
    struct Key: Sendable, Hashable {
        let body: String
        let effectiveWidth: Double
        let fontMetrics: FontMetrics
        let codeFontMetrics: FontMetrics?
        let codeRanges: [NSRange]
    }
    enum Observation: Sendable {
        case requested(Key)
        case completed(Key)
    }
    /// Completed scalar layouts belong to one opening, independently of candidate acceptance.
    final class OpeningLayouts: Sendable {
        private let completed = Mutex<[Key: PaneContextMessageBodyMeasurement]>([:])

        /// Inspect only after the owning projection or retirement has completed.
        var retainedLayoutCount: Int { completed.withLock { $0.count } }

        func retainCanonicalBodies(_ bodies: Set<String>) {
            completed.withLock { values in values = values.filter { bodies.contains($0.key.body) } }
        }

        func measurement(
            for key: Key, make: () -> PaneContextMessageBodyMeasurement
        ) -> (value: PaneContextMessageBodyMeasurement, reused: Bool) {
            completed.withLock { values in
                if let value = values[key] { return (value, true) }
                let value = make()
                values[key] = value
                return (value, false)
            }
        }

        @concurrent nonisolated func removeAll() async {
            completed.withLock { $0.removeAll() }
        }
    }
    let key: Key
    let visualLines: Int
    let collapsedPrefixUTF16Length: Int?

    static func prepare(
        body: String, font: PaneContextMessageBodyFont, codeRanges: [NSRange] = [],
        geometry: PaneContextMessageBodyGeometry,
        previous: Self?, performance: PaneContextPopoverPerformance,
        consumer: PaneContextPopoverConsumerKey, openingLayouts: OpeningLayouts? = nil
    ) -> Self {
        let resolved = font.paintFont.resolve(in: geometry.fontContext).ctFont
        let nativeFont = resolved as NSFont
        let codeFont =
            codeRanges.isEmpty
            ? nil
            : PaneContextMessageBodyText.codeFont.paintFont.resolve(in: geometry.fontContext).ctFont
        let key = Key(
            body: body, effectiveWidth: Double(geometry.effectiveWidth),
            fontMetrics: metrics(resolved, lineSpacing: font.lineSpacing),
            codeFontMetrics: codeFont.map { metrics($0, lineSpacing: font.lineSpacing) }, codeRanges: codeRanges)
        performance.bodyLayoutObserver?(.requested(key))
        let measure = { () -> Self in
            if let previous, previous.key == key {
                performance.record(.textLayoutReuse, key: consumer)
                return previous
            }
            let result = autoreleasepool {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = font.lineSpacing
                paragraph.lineBreakMode = .byWordWrapping
                let storage = NSTextStorage(string: body, attributes: [.font: nativeFont, .paragraphStyle: paragraph])
                if let codeFont {
                    for range in codeRanges { storage.addAttribute(.font, value: codeFont as NSFont, range: range) }
                }
                let manager = NSLayoutManager()
                manager.backgroundLayoutEnabled = false
                let container = NSTextContainer(
                    size: .init(width: geometry.effectiveWidth, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                var lines = 0
                var lastVisibleLine: NSRange?
                let laidOutGlyphRange = manager.glyphRange(for: container)
                manager.enumerateLineFragments(forGlyphRange: laidOutGlyphRange) { _, _, _, glyphs, _ in
                    lines += 1
                    if lines == AppPolicies.PaneContext.collapsedMessageBodyLines { lastVisibleLine = glyphs }
                }
                let count = lines + (body.last?.isNewline == true ? 1 : 0)
                let prefix =
                    count > AppPolicies.PaneContext.collapsedMessageBodyLines
                    ? lastVisibleLine.map {
                        collapsedPrefix(
                            body: body, storage: storage, manager: manager, line: $0,
                            width: geometry.effectiveWidth, fallbackFont: nativeFont)
                    } : nil
                return (count, prefix)
            }
            performance.textLayoutCompleted(key: consumer, measurement: key)
            return .init(key: key, visualLines: result.0, collapsedPrefixUTF16Length: result.1)
        }
        if let openingLayouts {
            let retained = openingLayouts.measurement(for: key, make: measure)
            if retained.reused { performance.record(.textLayoutReuse, key: consumer) }
            return retained.value
        }
        return measure()
    }

    /// Reuses the completed glyph layout; no second TextKit graph or layout is created.
    private static func collapsedPrefix(
        body: String, storage: NSTextStorage, manager: NSLayoutManager, line: NSRange,
        width: CGFloat, fallbackFont: NSFont
    ) -> Int {
        let source = body as NSString
        var end = NSMaxRange(manager.characterRange(forGlyphRange: line, actualGlyphRange: nil))
        while end > 0 {
            end = source.rangeOfComposedCharacterSequence(at: end - 1).location
            while end > 0 {
                let last = source.rangeOfComposedCharacterSequence(at: end - 1)
                let character = source.substring(with: last)
                guard
                    character.unicodeScalars.allSatisfy({
                        CharacterSet.whitespacesAndNewlines.contains($0)
                            || CharacterSet.punctuationCharacters.contains($0)
                    })
                else { break }
                end = last.location
            }
            guard end > 0 else { return 0 }
            let prefix = manager.glyphRange(
                forCharacterRange: .init(location: 0, length: end), actualCharacterRange: nil)
            let nextGlyph = NSMaxRange(prefix)
            if nextGlyph < line.location { return end }
            guard nextGlyph < NSMaxRange(line) else { continue }
            let font = storage.attribute(.font, at: end - 1, effectiveRange: nil) as? NSFont ?? fallbackFont
            var character: UniChar = 0x2026
            var glyph = CGGlyph()
            CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
            if manager.location(forGlyphAt: nextGlyph).x + advance.width <= width { return end }
        }
        return 0
    }

    private static func metrics(_ resolved: CTFont, lineSpacing: CGFloat) -> FontMetrics {
        let transform = CTFontGetMatrix(resolved)
        let axes = (CTFontCopyVariation(resolved) as? [NSNumber: NSNumber] ?? [:])
            .map { Axis(identifier: $0.key.intValue, value: $0.value.doubleValue) }
            .sorted { $0.identifier < $1.identifier }
        let features = (CTFontCopyFeatureSettings(resolved) as? [[String: NSNumber]] ?? [])
            .compactMap { settings -> Feature? in
                guard let type = settings[kCTFontFeatureTypeIdentifierKey as String],
                    let selector = settings[kCTFontFeatureSelectorIdentifierKey as String]
                else { return nil }
                return .init(type: type.intValue, selector: selector.intValue)
            }.sorted { $0.type == $1.type ? $0.selector < $1.selector : $0.type < $1.type }
        return FontMetrics(
            name: CTFontCopyPostScriptName(resolved) as String, pointSize: Double(CTFontGetSize(resolved)),
            traits: CTFontGetSymbolicTraits(resolved).rawValue,
            matrix: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init),
            variations: axes, features: features,
            ascent: Double(CTFontGetAscent(resolved)), descent: Double(CTFontGetDescent(resolved)),
            leading: Double(CTFontGetLeading(resolved)), lineSpacing: Double(lineSpacing))
    }
}

extension PaneContextPopoverShapingKernel {
    static func prepareBodyLayouts(
        _ model: MessagesPopoverModel,
        geometry: [PaneContextTextBodyKey: PaneContextMessageBodyGeometry],
        baseline: [PaneContextTextBodyKey: PaneContextMessageBodyMeasurement],
        performance: PaneContextPopoverPerformance, consumer: PaneContextPopoverConsumerKey,
        openingLayouts: PaneContextMessageBodyMeasurement.OpeningLayouts? = nil
    ) -> (model: MessagesPopoverModel, measurements: [PaneContextTextBodyKey: PaneContextMessageBodyMeasurement]) {
        if let openingLayouts {
            let bodies = Set(
                model.groups.flatMap { group in
                    group.items.map { item in
                        switch item {
                        case .message(let row): row.bodyText.plainText
                        case .providerPrompt(let prompt): prompt.bodyText.plainText
                        }
                    }
                })
            openingLayouts.retainCanonicalBodies(bodies)
        }
        var measurements: [PaneContextTextBodyKey: PaneContextMessageBodyMeasurement] = [:]
        let template = PaneContextPopoverControlProjection.controls().showDetails
        let groups = model.groups.map { group in
            let items = group.items.map { item -> MessagesListItemModel in
                let key: PaneContextTextBodyKey
                let body: String
                let font: PaneContextMessageBodyFont
                let codeRanges: [NSRange]
                switch item {
                case .message(let row):
                    key = .message(row.key)
                    body = row.bodyText.plainText
                    font = row.bodyFont
                    codeRanges = row.bodyText.codeRanges
                case .providerPrompt(let prompt):
                    key = prompt.textBodyKey
                    body = prompt.bodyText.plainText
                    font = prompt.bodyFont
                    codeRanges = prompt.bodyText.codeRanges
                }
                guard let capture = geometry[key], capture.effectiveWidth > 0 else { return item }
                let measurement = PaneContextMessageBodyMeasurement.prepare(
                    body: body, font: font, codeRanges: codeRanges, geometry: capture, previous: baseline[key],
                    performance: performance, consumer: consumer, openingLayouts: openingLayouts)
                measurements[key] = measurement
                let details =
                    measurement.visualLines > AppPolicies.PaneContext.collapsedMessageBodyLines
                    ? template : nil
                let layout = PaneContextMessageBodyLayout.ready(
                    geometry: capture, visualLines: measurement.visualLines, details: details,
                    preview: measurement.collapsedPrefixUTF16Length.map { length in
                        switch item {
                        case .message(let row): row.bodyText.collapsedPaint(prefixUTF16Length: length)
                        case .providerPrompt(let prompt): prompt.bodyText.collapsedPaint(prefixUTF16Length: length)
                        }
                    })
                switch item {
                case .message(let row): return .message(row.replacingBodyLayout(layout))
                case .providerPrompt(let prompt): return .providerPrompt(prompt.replacingBodyLayout(layout))
                }
            }
            return MessagesGroupModel(
                kind: group.kind, items: items,
                omittedPromptCount: group.omittedPromptCount, header: group.header)
        }
        return (model.replacingGroups(groups), measurements)
    }
}
