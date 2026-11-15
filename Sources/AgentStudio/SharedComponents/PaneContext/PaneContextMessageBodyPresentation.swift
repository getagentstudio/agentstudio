import AgentStudioInfrastructure
import Foundation
import SwiftUI

/// The one paint-font source used by the view and by worker-side font resolution.
package enum PaneContextMessageBodyFont: Sendable, Equatable {
    case proportional(pointSize: CGFloat)
    case monospaced(pointSize: CGFloat)

    package var paintFont: Font {
        switch self {
        case .proportional(let size): .system(size: size)
        case .monospaced(let size): .system(size: size, design: .monospaced)
        }
    }

    package var lineSpacing: CGFloat {
        switch self {
        case .proportional: AppStyles.Components.PaneContext.bodyLineSpacing
        case .monospaced: AppStyles.Components.PaneContext.monospacedLineSpacing
        }
    }

    func pendingCharacterLimit(width: CGFloat) -> Int {
        let effectiveWidth =
            width.isFinite && width > 0 ? width : AppStyles.Components.PaneContext.messagesPopoverMaximumWidth
        let size: CGFloat
        let monospaced: Bool
        switch self {
        case .proportional(let pointSize): (size, monospaced) = (pointSize, false)
        case .monospaced(let pointSize): (size, monospaced) = (pointSize, true)
        }
        return AppPolicies.PaneContext.pendingMessageBodyCharacterLimit(
            width: effectiveWidth, fontPointSize: size, monospaced: monospaced,
            codeFontPointSize: AppStyles.General.Typography.textXs)
    }
}

/// Prepared in the shaping worker; paint and TextKit consume the same explicit code spans.
package struct PaneContextMessageBodyText: Sendable, Equatable {
    private let effectiveBaseFont: PaneContextMessageBodyFont?
    package let plainText: String
    package let paint: AttributedString
    package let codeRanges: [NSRange]

    package init(_ body: String, font: PaneContextMessageBodyFont) {
        let content = Self.fencedContent(in: body)
        // A fully overridden or empty base font cannot change the attributed paint.
        effectiveBaseFont = content.ranges.reduce(0) { $0 + $1.length } == content.text.utf16.count ? nil : font
        plainText = content.text
        codeRanges = content.ranges
        var paint = AttributedString(content.text)
        paint.font = font.paintFont
        for range in codeRanges {
            if let indices = Range<AttributedString.Index>(range, in: paint) {
                paint[indices].font = Self.codeFont.paintFont
            }
        }
        self.paint = paint
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.plainText == rhs.plainText && lhs.codeRanges == rhs.codeRanges
            && lhs.effectiveBaseFont == rhs.effectiveBaseFont
    }

    package static let codeFont = PaneContextMessageBodyFont.monospaced(pointSize: AppStyles.General.Typography.textXs)

    package func collapsedPaint(prefixUTF16Length: Int) -> AttributedString {
        let range = NSRange(location: 0, length: prefixUTF16Length)
        guard let indices = Range<AttributedString.Index>(range, in: paint) else { return paint }
        var prefix = AttributedString(paint[indices])
        var ellipsis = AttributedString("…")
        ellipsis.font = prefix.runs.last?.font ?? paint.runs.first?.font
        prefix.append(ellipsis)
        return prefix
    }

    private static func fencedContent(in body: String) -> (text: String, ranges: [NSRange]) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var delimiters = Set<Int>()
        var codeLines = Set<Int>()
        var opening: (line: Int, ticks: Int)?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix(while: { $0 == "`" }).count
            if let start = opening {
                if ticks >= start.ticks, trimmed.dropFirst(ticks).allSatisfy(\.isWhitespace) {
                    delimiters.formUnion([start.line, index])
                    codeLines.formUnion((start.line + 1)..<index)
                    opening = nil
                }
            } else if ticks >= 3, !trimmed.dropFirst(ticks).contains("`") {
                opening = (index, ticks)
            }
        }
        var text = ""
        var hasLine = false
        var ranges: [NSRange] = []
        for (index, line) in lines.enumerated() where !delimiters.contains(index) {
            if hasLine { text += "\n" }
            hasLine = true
            let start = text.utf16.count
            text += line
            if codeLines.contains(index) { ranges.append(.init(location: start, length: line.utf16.count)) }
        }
        return (text, ranges)
    }

}

/// Body geometry uses the list's canonical message/provider identity.
package typealias PaneContextTextBodyKey = MessagesListItemModel.ItemIdentity

extension MessagesListItemModel.ItemIdentity {
    package var textIdentifier: String {
        switch self {
        case .message(let key): "pane-context.message-text." + key.controlScope
        case .providerPrompt(let source, let ordinal): "pane-context.provider-prompt.\(source).\(ordinal)"
        }
    }
}

/// Actual layout inputs copied by the UI; font resolution and text layout stay in the worker.
package struct PaneContextMessageBodyGeometry: Equatable, Sendable {
    package let effectiveWidth: CGFloat
    package let fontContext: Font.Context
    package init(effectiveWidth: CGFloat, fontContext: Font.Context) {
        self.effectiveWidth = effectiveWidth
        self.fontContext = fontContext
    }
}

package enum PaneContextMessageBodyLayout: Equatable, Sendable {
    case pendingWidth
    case ready(
        geometry: PaneContextMessageBodyGeometry, visualLines: Int, details: PaneContextControlModel?,
        preview: AttributedString? = nil)
}
