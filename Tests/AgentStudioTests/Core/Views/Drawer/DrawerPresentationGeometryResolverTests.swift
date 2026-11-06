import CoreGraphics
import Foundation
import Testing

@testable import AgentStudioCore

/// Expected values come from the drawer presentation Specification and
/// Program Design (0.97 × region width centered, 0.95 × region height
/// including the connector, bottom at region bottom, existing normal
/// metrics), computed by hand — never by calling the resolver.
@Suite
struct DrawerPresentationGeometryResolverTests {
    private let tolerance: CGFloat = 0.001

    // MARK: - Pane Zoom

    @Test("Zoom terminal side: 97% width centered, 95% height, bottom at region bottom, no handle")
    func zoomTerminalSideShape() throws {
        let geometry = try #require(
            resolveZoom(
                side: .terminal,
                terminal: CGRect(x: 0, y: 0, width: 700, height: 600),
                bridge: CGRect(x: 702, y: 0, width: 298, height: 600)
            )
        )

        #expect(geometry.mode == .zoom(effectiveSide: .terminal))
        expectRect(geometry.outlineFrame, CGRect(x: 10.5, y: 30, width: 679, height: 570))
        // Upper 5% of the 600pt region is exposed; nothing is deducted for the footer.
        #expect(abs(geometry.outlineFrame.minY - 30) < tolerance)
        #expect(abs(geometry.outlineFrame.maxY - 600) < tolerance)
        expectRect(geometry.panelFrame, CGRect(x: 10.5, y: 30, width: 679, height: 530))
        expectRect(geometry.connectorFrame, CGRect(x: 10.5, y: 560, width: 679, height: 40))
        expectRect(geometry.childContentFrame, CGRect(x: 18.5, y: 38, width: 663, height: 514))
        expectRect(geometry.dismissalFrame, geometry.outlineFrame)
        #expect(geometry.resizeHandleFrame == nil)
    }

    @Test("Zoom Bridge side at 70/30 fits the 30% region, not half the workspace")
    func zoomBridgeSideUsesActualRegionWidth() throws {
        let bridge = CGRect(x: 700, y: 0, width: 300, height: 600)
        let geometry = try #require(
            resolveZoom(side: .bridge, terminal: CGRect(x: 0, y: 0, width: 699, height: 600), bridge: bridge)
        )

        #expect(geometry.mode == .zoom(effectiveSide: .bridge))
        expectRect(geometry.outlineFrame, CGRect(x: 704.5, y: 30, width: 291, height: 570))
        // Gutter visible on both sides of the region.
        #expect(geometry.outlineFrame.minX > bridge.minX)
        #expect(geometry.outlineFrame.maxX < bridge.maxX)
        #expect(
            abs((geometry.outlineFrame.minX - bridge.minX) - (bridge.maxX - geometry.outlineFrame.maxX)) < tolerance)
        // Connector bottom spans the center two thirds of the region.
        #expect(abs(geometry.connectorInsets.bottomLeft - 50) < tolerance)
        #expect(abs(geometry.connectorInsets.bottomRight - 50) < tolerance)
    }

    @Test("A pane with no saved choice opens its Zoom drawer on the Bridge side")
    func zoomDefaultPreferenceUsesBridgeRegion() throws {
        let bridge = CGRect(x: 700, y: 0, width: 300, height: 600)
        let input = DrawerPresentationGeometryInput(
            containerBounds: CGRect(x: 0, y: 0, width: 1000, height: 640),
            preference: .default,
            placement: .zoom(terminalRegion: CGRect(x: 0, y: 0, width: 699, height: 600), visibleBridgeRegion: bridge)
        )

        let geometry = try #require(DrawerPresentationGeometryResolver.resolve(input))

        #expect(geometry.mode == .zoom(effectiveSide: .bridge))
        expectRect(geometry.outlineFrame, CGRect(x: 704.5, y: 30, width: 291, height: 570))
    }

    @Test("Hidden Bridge falls back to the terminal region without changing the preference")
    func zoomHiddenBridgeFallsBackToTerminal() throws {
        let preference = DrawerPresentationPreference.default.replacingZoomSide(.bridge)
        let input = DrawerPresentationGeometryInput(
            containerBounds: CGRect(x: 0, y: 0, width: 1000, height: 640),
            preference: preference,
            placement: .zoom(terminalRegion: CGRect(x: 0, y: 0, width: 999, height: 600), visibleBridgeRegion: nil)
        )

        let geometry = try #require(DrawerPresentationGeometryResolver.resolve(input))

        #expect(geometry.mode == .zoom(effectiveSide: .terminal))
        expectRect(geometry.outlineFrame, CGRect(x: 14.985, y: 30, width: 969.03, height: 570))
        #expect(input.preference.zoomSide == .bridge)
    }

    @Test("Zoom with an empty Bridge region also falls back to terminal")
    func zoomEmptyBridgeRegionFallsBack() throws {
        let geometry = try #require(
            resolveZoom(
                side: .bridge,
                terminal: CGRect(x: 0, y: 0, width: 500, height: 400),
                bridge: CGRect(x: 500, y: 0, width: 0, height: 400)
            )
        )
        #expect(geometry.mode == .zoom(effectiveSide: .terminal))
    }

    @Test("Zoom connector yields its height before the panel falls below its minimum")
    func zoomShortRegionShrinksConnector() throws {
        let geometry = try #require(
            resolveZoom(side: .terminal, terminal: CGRect(x: 0, y: 0, width: 400, height: 130), bridge: nil)
        )
        // outline 0.95 × 130 = 123.5; connector = min(40, 123.5 - 100) = 23.5
        #expect(abs(geometry.connectorFrame.height - 23.5) < tolerance)
        #expect(abs(geometry.panelFrame.height - 100) < tolerance)
        #expect(abs(geometry.outlineFrame.maxY - 130) < tolerance)
    }

    @Test(
        "Zoom unavailable inputs yield no geometry",
        arguments: [
            CGRect(x: 0, y: 0, width: 400, height: 10),
            CGRect(x: 0, y: 0, width: 0, height: 400),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 400),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400),
        ]
    )
    func zoomUnavailableInputs(terminal: CGRect) {
        #expect(resolveZoom(side: .terminal, terminal: terminal, bridge: nil) == nil)
    }

    @Test(
        "Zoom outline stays inside its region for equal and unequal splits",
        arguments: [0.3, 0.5, 0.7] as [CGFloat]
    )
    func zoomOutlineStaysInsideRegion(ratio: CGFloat) throws {
        let splitArea = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let regions = DrawerPresentationGeometryResolver.zoomRegions(
            splitArea: splitArea,
            sourceSplitRatio: ratio,
            reservesCompanionSpace: true,
            isCompanionVisible: true
        )
        for side in DrawerZoomSide.allCases {
            let geometry = try #require(resolveZoom(side: side, terminal: regions.terminal, bridge: regions.bridge))
            let region = side == .terminal ? regions.terminal : try #require(regions.bridge)
            #expect(geometry.outlineFrame.minX >= region.minX)
            #expect(geometry.outlineFrame.maxX <= region.maxX)
            #expect(abs(geometry.outlineFrame.maxY - region.maxY) < tolerance)
            #expect(abs(geometry.outlineFrame.width - region.width * 0.97) < tolerance)
            #expect(abs(geometry.outlineFrame.minY - (region.minY + region.height * 0.05)) < tolerance)
        }
    }

    // MARK: - Zoom regions

    @Test("Zoom regions follow the split divider arithmetic")
    func zoomRegionsFromSplitArea() throws {
        let splitArea = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let visible = DrawerPresentationGeometryResolver.zoomRegions(
            splitArea: splitArea,
            sourceSplitRatio: 0.7,
            reservesCompanionSpace: true,
            isCompanionVisible: true
        )
        expectRect(visible.terminal, CGRect(x: 0, y: 0, width: 699, height: 600))
        expectRect(try #require(visible.bridge), CGRect(x: 700, y: 0, width: 300, height: 600))

        let hidden = DrawerPresentationGeometryResolver.zoomRegions(
            splitArea: splitArea,
            sourceSplitRatio: 0.7,
            reservesCompanionSpace: true,
            isCompanionVisible: false
        )
        expectRect(hidden.terminal, CGRect(x: 0, y: 0, width: 999, height: 600))
        #expect(hidden.bridge == nil)
    }

    // MARK: - Normal

    @Test("Normal: saved ratio, toolbar subtracted once, connector included, handle on top")
    func normalSavedRatioShape() throws {
        let geometry = try #require(
            resolveNormal(
                ratio: 0.5,
                container: CGRect(x: 0, y: 0, width: 1000, height: 800),
                owner: CGRect(x: 0, y: 0, width: 500, height: 800),
                toolbarHeight: 32
            )
        )

        #expect(geometry.mode == .normal)
        expectRect(geometry.outlineFrame, CGRect(x: 4, y: 328, width: 800, height: 440))
        expectRect(geometry.panelFrame, CGRect(x: 4, y: 328, width: 800, height: 400))
        expectRect(geometry.connectorFrame, CGRect(x: 4, y: 728, width: 800, height: 40))
        expectRect(geometry.childContentFrame, CGRect(x: 12, y: 336, width: 784, height: 384))
        expectRect(try #require(geometry.resizeHandleFrame), CGRect(x: 4, y: 328, width: 800, height: 8))
        #expect(abs(geometry.connectorInsets.junctionLeft - 0) < tolerance)
        #expect(abs(geometry.connectorInsets.junctionRight - 304) < tolerance)
        #expect(abs(geometry.connectorInsets.bottomLeft - 500.0 / 6) < tolerance)
        #expect(abs(geometry.connectorInsets.bottomRight - (304 + 500.0 / 6)) < tolerance)
    }

    @Test(
        "Normal live height overrides the ratio within the height bounds",
        arguments: [
            (live: 300 as CGFloat, expected: 300 as CGFloat),
            (live: 900, expected: 640),
            (live: 20, expected: 160),
        ]
    )
    func normalLiveHeightBounds(live: CGFloat, expected: CGFloat) throws {
        let geometry = try #require(
            resolveNormal(
                ratio: 0.5,
                container: CGRect(x: 0, y: 0, width: 1000, height: 800),
                owner: CGRect(x: 0, y: 0, width: 500, height: 800),
                toolbarHeight: 32,
                liveHeight: live
            )
        )
        #expect(abs(geometry.panelFrame.height - expected) < tolerance)
    }

    @Test("Normal height bounds keep the existing limits")
    func normalHeightBounds() {
        let bounds = DrawerPresentationGeometryResolver.normalPanelHeightBounds(containerHeight: 800)
        #expect(bounds == 160...640)
        let shortBounds = DrawerPresentationGeometryResolver.normalPanelHeightBounds(containerHeight: 300)
        #expect(shortBounds == 100...240)
    }

    @Test("Normal panel is display-clamped to the owner's available space, never above the container")
    func normalDisplayClampToAvailableSpace() throws {
        let geometry = try #require(
            resolveNormal(
                ratio: 0.8,
                container: CGRect(x: 0, y: 0, width: 600, height: 300),
                owner: CGRect(x: 0, y: 0, width: 600, height: 300),
                toolbarHeight: 32
            )
        )
        // Requested 240; outline bottom 268 leaves 228 for the panel above the 40pt connector.
        #expect(abs(geometry.panelFrame.height - 228) < tolerance)
        #expect(abs(geometry.outlineFrame.minY) < tolerance)
    }

    @Test("Normal unavailable inputs yield no geometry")
    func normalUnavailableInputs() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(
            resolveNormal(
                ratio: 0.5,
                container: container,
                owner: CGRect(x: 0, y: 0, width: 500, height: 40),
                toolbarHeight: 32
            ) == nil
        )
        #expect(
            resolveNormal(
                ratio: 0.5,
                container: .zero,
                owner: CGRect(x: 0, y: 0, width: 500, height: 800),
                toolbarHeight: 32
            ) == nil
        )
        #expect(
            resolveNormal(
                ratio: 0.5,
                container: container,
                owner: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 800),
                toolbarHeight: 32
            ) == nil
        )
    }

    // MARK: - Preference validation

    @Test("Preference ratios are finite and clamped to the saved range")
    func preferenceRatioValidation() {
        #expect(DrawerPresentationPreference.validatedNormalHeightRatio(.nan) == nil)
        #expect(DrawerPresentationPreference.validatedNormalHeightRatio(.infinity) == nil)
        #expect(DrawerPresentationPreference.validatedNormalHeightRatio(0.05) == 0.2)
        #expect(DrawerPresentationPreference.validatedNormalHeightRatio(0.95) == 0.8)
        #expect(DrawerPresentationPreference.validatedNormalHeightRatio(0.5) == 0.5)
        #expect(DrawerPresentationPreference.default.normalHeightRatio == 0.8)
        #expect(DrawerPresentationPreference.default.zoomSide == .bridge)
    }

    // MARK: - Helpers

    private func resolveZoom(
        side: DrawerZoomSide,
        terminal: CGRect,
        bridge: CGRect?
    ) -> DrawerPresentationGeometry? {
        DrawerPresentationGeometryResolver.resolve(
            DrawerPresentationGeometryInput(
                containerBounds: CGRect(x: 0, y: 0, width: 1000, height: 640),
                preference: DrawerPresentationPreference.default.replacingZoomSide(side),
                placement: .zoom(terminalRegion: terminal, visibleBridgeRegion: bridge)
            )
        )
    }

    private func resolveNormal(
        ratio: Double,
        container: CGRect,
        owner: CGRect,
        toolbarHeight: CGFloat,
        liveHeight: CGFloat? = nil
    ) -> DrawerPresentationGeometry? {
        DrawerPresentationGeometryResolver.resolve(
            DrawerPresentationGeometryInput(
                containerBounds: container,
                preference: DrawerPresentationPreference(normalHeightRatio: ratio, zoomSide: .terminal),
                placement: .normal(ownerFrame: owner, ownerToolbarHeight: toolbarHeight, liveHeight: liveHeight)
            )
        )
    }

    private func expectRect(
        _ actual: CGRect,
        _ expected: CGRect,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let matches =
            abs(actual.minX - expected.minX) < tolerance
            && abs(actual.minY - expected.minY) < tolerance
            && abs(actual.width - expected.width) < tolerance
            && abs(actual.height - expected.height) < tolerance
        #expect(matches, "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }
}
