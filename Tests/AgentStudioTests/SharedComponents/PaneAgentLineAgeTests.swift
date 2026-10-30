import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Shared sidebar Agent Line age", .serialized)
struct PaneAgentLineAgeTests {
    @Test("age keeps the sidebar's exact typography, dim paint and spacing", arguments: ["[Now]", "[2 min ago]"])
    func sidebarPaint(age: String) throws {
        let actual = try bitmap(PaneAgentLineAge(age, identifier: "proof.age"))
        // The source oracle is RepoExplorerPaneContextLineView before extraction: 12pt, secondary, leading space.
        let expected = try bitmap(
            Text(" " + age).font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1).fixedSize())

        #expect(actual.pixelsWide == expected.pixelsWide)
        #expect(actual.pixelsHigh == expected.pixelsHigh)
        let matches = (0..<actual.pixelsHigh).allSatisfy { y in
            (0..<actual.pixelsWide).allSatisfy { x in
                actual.colorAt(x: x, y: y) == expected.colorAt(x: x, y: y)
            }
        }
        #expect(matches, "Age font, dim color and spacing must match the checked sidebar source")
    }

    @Test(
        "shared text and age preserve the sidebar clamp and whole suffix",
        arguments: ["Short", "Running Swift tests • 212/412"])
    func sidebarTextAndAge(summary: String) throws {
        let actual = try bitmap(
            PaneAgentLineText(
                Text(summary).font(.system(size: 12)).foregroundColor(.primary),
                ageText: "[2 min ago]", maximumTextWidth: 70
            ).lineLimit(1).truncationMode(.tail))
        // The pre-extraction sidebar composition, with literal source typography and clamp.
        let expected = try bitmap(
            AdjacentAgeLayout(maximumTextWidth: 70) {
                Text(summary).font(.system(size: 12)).foregroundStyle(Color.primary)
                    .lineLimit(1).truncationMode(.tail)
                Text(" [2 min ago]").font(.system(size: 12)).foregroundStyle(Color.secondary)
                    .lineLimit(1).fixedSize()
            })
        #expect(actual.pixelsWide == expected.pixelsWide)
        #expect(actual.pixelsHigh == expected.pixelsHigh)
        #expect(
            (0..<actual.pixelsHigh).allSatisfy { y in
                (0..<actual.pixelsWide).allSatisfy { x in
                    actual.colorAt(x: x, y: y) == expected.colorAt(x: x, y: y)
                }
            }, "Shared presentation must preserve the source sidebar pixels, including the full suffix")
    }

    private func bitmap<Content: View>(_ view: Content) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView:
                view
                .frame(width: 140, height: 24, alignment: .leading)
                .background(Color.black).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 140, height: 24)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
