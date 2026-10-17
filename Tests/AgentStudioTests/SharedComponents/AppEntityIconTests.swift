import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@Suite("AppEntityIcon")
struct AppEntityIconTests {
    /// A source-string assertion caught a naming defect but missed that the earlier outer
    /// `.foregroundStyle(...)` wrap never actually painted the icon: `swiftUIImage` bakes its own
    /// `.foregroundStyle` at the leaf, so SwiftUI resolves the innermost style regardless of what an
    /// outer wrapper applies. This test renders real pixels and samples the glyph color directly so a
    /// future regression on this exact failure mode fails a real proof, not just a text match.
    @Test("foregroundOverride paints the icon; the baked default never leaks through it")
    @MainActor
    func foregroundOverrideWinsOverBakedDefaultStyle() throws {
        let loader = OcticonLoader(resourceBundle: .main)

        let defaultColor = try centerGlyphColor(
            in: renderBitmap(
                AppEntityIcon.pane.swiftUIImage(loader: loader, size: 24)
                    .frame(width: 40, height: 40)
                    .background(Color.black),
                size: CGSize(width: 40, height: 40)
            ))
        let overriddenColor = try centerGlyphColor(
            in: renderBitmap(
                AppEntityIcon.pane.swiftUIImage(
                    loader: loader,
                    size: 24,
                    foregroundOverride: AppStyles.General.Accent.primaryColor
                )
                .frame(width: 40, height: 40)
                .background(Color.black),
                size: CGSize(width: 40, height: 40)
            ))

        // `.secondary` renders as a near-neutral gray: red and blue stay close together.
        #expect(abs(defaultColor.red - defaultColor.blue) < 0.08)

        // The accent override (#409CFF) is a saturated blue: blue clearly dominates red, and clearly
        // exceeds the ungraded default's blue channel.
        #expect(overriddenColor.blue - overriddenColor.red > 0.15)
        #expect(overriddenColor.blue > defaultColor.blue)
    }

    @MainActor
    private func renderBitmap<Content: View>(_ view: Content, size: CGSize) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.setFrameSize(size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    /// Samples the brightest pixel near the view's center, where the glyph renders against the black
    /// background.
    private func centerGlyphColor(
        in bitmap: NSBitmapImageRep
    ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var brightest: NSColor?
        var brightestSum: CGFloat = 0
        let midX = bitmap.pixelsWide / 2
        let midY = bitmap.pixelsHigh / 2
        for dx in -6...6 {
            for dy in -6...6 {
                guard let color = bitmap.colorAt(x: midX + dx, y: midY + dy)?.usingColorSpace(.deviceRGB)
                else { continue }
                let sum = color.redComponent + color.greenComponent + color.blueComponent
                if sum > brightestSum {
                    brightestSum = sum
                    brightest = color
                }
            }
        }
        let color = try #require(brightest)
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }
}
