import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import CoreText
import Foundation
import SwiftUI

/// Only scalar/value results survive the private TextKit graph's synchronous lifetime.
struct PaneContextMessageBodyMeasurement: Sendable, Equatable {
    struct Axis: Sendable, Equatable {
        let identifier: Int
        let value: Double
    }
    struct Feature: Sendable, Equatable {
        let type: Int
        let selector: Int
    }
    struct FontMetrics: Sendable, Equatable {
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
    struct Key: Sendable, Equatable {
        let body: String
        let effectiveWidth: Double
        let fontMetrics: FontMetrics
    }
    let key: Key
    let visualLines: Int

    static func prepare(
        row: MessageRowModel, geometry: PaneContextMessageBodyGeometry,
        previous: Self?, performance: PaneContextPopoverPerformance,
        consumer: PaneContextPopoverConsumerKey
    ) -> Self {
        let resolved = row.bodyFont.paintFont.resolve(in: geometry.fontContext).ctFont
        let nativeFont = resolved as NSFont
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
        let metrics = FontMetrics(
            name: CTFontCopyPostScriptName(resolved) as String, pointSize: Double(CTFontGetSize(resolved)),
            traits: CTFontGetSymbolicTraits(resolved).rawValue,
            matrix: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init),
            variations: axes, features: features,
            ascent: Double(CTFontGetAscent(resolved)), descent: Double(CTFontGetDescent(resolved)),
            leading: Double(CTFontGetLeading(resolved)), lineSpacing: Double(row.bodyFont.lineSpacing))
        let key = Key(body: row.body, effectiveWidth: Double(geometry.effectiveWidth), fontMetrics: metrics)
        if let previous, previous.key == key {
            performance.record(.textLayoutReuse, key: consumer)
            return previous
        }
        let count = autoreleasepool {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = row.bodyFont.lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            let storage = NSTextStorage(string: row.body, attributes: [.font: nativeFont, .paragraphStyle: paragraph])
            let manager = NSLayoutManager()
            manager.backgroundLayoutEnabled = false
            let container = NSTextContainer(
                size: .init(width: geometry.effectiveWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
                lines += 1
            }
            return lines + (row.body.last?.isNewline == true ? 1 : 0)
        }
        performance.textLayoutCompleted(key: consumer)
        return .init(key: key, visualLines: count)
    }
}

extension PaneContextPopoverShapingKernel {
    static func prepareBodyLayouts(
        _ model: MessagesPopoverModel,
        geometry: [MessageRowModel.Key: PaneContextMessageBodyGeometry],
        baseline: [MessageRowModel.Key: PaneContextMessageBodyMeasurement],
        performance: PaneContextPopoverPerformance, consumer: PaneContextPopoverConsumerKey
    ) -> (model: MessagesPopoverModel, measurements: [MessageRowModel.Key: PaneContextMessageBodyMeasurement]) {
        var measurements: [MessageRowModel.Key: PaneContextMessageBodyMeasurement] = [:]
        let template = PaneContextPopoverControlProjection.controls().showMoreLines
        let groups = model.groups.map { group in
            let items = group.items.map { item -> MessagesListItemModel in
                guard case .message(let row) = item, let capture = geometry[row.key], capture.effectiveWidth > 0 else {
                    return item
                }
                let measurement = PaneContextMessageBodyMeasurement.prepare(
                    row: row, geometry: capture, previous: baseline[row.key], performance: performance,
                    consumer: consumer)
                measurements[row.key] = measurement
                let hidden = max(0, measurement.visualLines - AppPolicies.PaneContext.collapsedMessageBodyLines)
                let more: PaneContextControlModel? =
                    hidden > 0
                    ? .init(
                        identifier: template.identifier, label: String(format: template.label, hidden),
                        icon: template.icon, tooltip: template.tooltip,
                        accessibilityHelp: template.accessibilityHelp) : nil
                return .message(
                    row.replacingBodyLayout(
                        .ready(
                            geometry: capture, visualLines: measurement.visualLines, more: more)))
            }
            return MessagesGroupModel(
                kind: group.kind, items: items,
                omittedPromptCount: group.omittedPromptCount, header: group.header)
        }
        return (model.replacingGroups(groups), measurements)
    }
}
