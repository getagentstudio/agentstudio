import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

extension PaneContextPopoverRedesignTests {
    @Test("Question and required-field Submit use identical enabled app-token paint")
    func primarySubmitMatchesAcrossRealForms() throws {
        let submit = PaneContextControlModel(
            identifier: "proof.primary-submit", label: "Submit", icon: .system("checkmark"),
            tooltip: .init(text: "Submit", shortcutDisplayText: nil))
        var questionDraft = AskFormDraft()
        questionDraft.text = "Evidence"
        var requiredDraft = AskFormDraft()
        requiredDraft.fields["workspace"] = "~/code/projects/agentstudio"
        let property = ElicitationPropertyModel(
            name: "workspace", title: "Workspace", description: nil, required: true,
            kind: .string(choices: nil, minLength: nil, maxLength: nil, format: nil))
        var question: PrimarySubmitRaster?
        var required: PrimarySubmitRaster?
        var literal: PrimarySubmitRaster?
        try withMounted(
            AskAnswerForm(
                form: .freeText(placeholder: "Reply"), draft: .constant(questionDraft),
                submitControl: submit, layout: .messages, onSubmit: { _ in })
        ) { host in
            let found = findButton(in: host)
            let button = try #require(found)
            #expect(button.isAccessibilityEnabled())
            question = try submitRaster(host, bounds: button.convert(button.bounds, to: host))
        }
        try withMounted(
            AskAnswerForm(
                form: .elicitation([property]), draft: .constant(requiredDraft),
                submitControl: submit, layout: .messages, onSubmit: { _ in })
        ) { host in
            let found = findButton(in: host)
            let button = try #require(found)
            #expect(button.isAccessibilityEnabled())
            required = try submitRaster(host, bounds: button.convert(button.bounds, to: host))
        }
        try withMounted(
            Text("Submit").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.sRGB, red: 29 / 255, green: 31 / 255, blue: 33 / 255))
                .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color(.sRGB, red: 64 / 255, green: 156 / 255, blue: 1))
                )
                .background(
                    AccessibilityLabelBridge(identifier: "proof.literal-submit", label: "Submit", role: .staticText)
                )
                .background(Color.primary.opacity(0.04))
        ) { host in
            let found = findSubmitReference(in: host)
            let marker = try #require(found)
            literal = try submitRaster(host, bounds: marker.convert(marker.bounds, to: host))
        }
        let questionPaint = try #require(question)
        let requiredPaint = try #require(required)
        let literalPaint = try #require(literal)
        #expect(questionPaint == requiredPaint, "Both actual enabled form paths must produce identical Submit pixels")
        #expect(questionPaint == literalPaint, "Question Submit must use the literal main app-token recipe")
        #expect(requiredPaint == literalPaint, "Required-field Submit must use the literal main app-token recipe")
        print(
            "PRIMARY_SUBMIT_PAINT", "question", questionPaint.width, questionPaint.height, questionPaint.frequentColors,
            "required", requiredPaint.frequentColors, "literal", literalPaint.frequentColors)
    }

    private struct PrimarySubmitRaster: Equatable {
        let width: Int
        let height: Int
        let rgba: Data
        var frequentColors: [String] {
            let bytes = [UInt8](rgba)
            var counts: [String: Int] = [:]
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes[offset..<offset + 4].map(String.init).joined(separator: ",")
                counts[value, default: 0] += 1
            }
            return counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):\($0.value)" }
        }
    }

    private func submitRaster(_ host: NSView, bounds: CGRect) throws -> PrimarySubmitRaster {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let scale = CGFloat(image.width) / host.bounds.width
        let top = host.isFlipped ? bounds.minY : host.bounds.maxY - bounds.maxY
        let crop = CGRect(
            x: bounds.minX * scale, y: top * scale, width: bounds.width * scale, height: bounds.height * scale
        ).integral
        let button = try #require(image.cropping(to: crop))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: button.width * button.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: button.width, height: button.height,
                    bitsPerComponent: 8, bytesPerRow: button.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(button, in: CGRect(x: 0, y: 0, width: button.width, height: button.height))
        }
        return .init(width: button.width, height: button.height, rgba: Data(bytes))
    }

    private func findSubmitReference(in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == "proof.literal-submit" { return view }
        return view.subviews.lazy.compactMap { findSubmitReference(in: $0) }.first
    }
}
