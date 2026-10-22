import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityGeometryTests {
    @Test(arguments: PaneIdentityCardFixture.names)
    func fieldListKeepsItsOrderAlignmentAndFullIdentityAtEveryWidth(name: String) throws {
        let strip = PaneIdentityCardFixture.strip(name)
        let model = ManagementPaneIdentityPresentation(context: strip.context, lines: strip.lines)
        var heights: [CGFloat] = []
        let secondary = model.secondaryLines.map { String(describing: $0.kind) }
        let expectedOrder =
            ["title", "activity"] + secondary + model.rows.map(\.id)
            + (name == "card-3-like" ? [] : ["git"])
        for width in PaneIdentityCardFixture.widths {
            let mounted = PaneIdentityCardFixture.mount(strip, width: width)
            defer {
                mounted.window.contentView = nil
                mounted.window.close()
            }
            if width >= 520 { heights.append(mounted.host.fittingSize.height) }
            try PaneIdentityCardFixture.expectContained(in: mounted.host)
            let frames = PaneIdentityCardFixture.frames(in: mounted.host)
            for identifier in expectedOrder {
                #expect(frames[identifier] != nil, "\(name) @ \(width): missing line \(identifier)")
            }
            for (first, second) in zip(expectedOrder, expectedOrder.dropFirst()) {
                if let upper = frames[first], let lower = frames[second] {
                    #expect(upper.maxY <= lower.minY, "\(name) @ \(width): \(first) must precede \(second)")
                }
            }
            let values = model.rows.compactMap { frames["\($0.id).text"] }
            #expect(values.count == model.rows.count)
            #expect(Set(values.map(\.minX)).count == 1, "All field values must share their leading x")
            for row in model.rows where ["repo", "branch", "pane"].contains(row.id) {
                // Deliberately oversized names exercise the brief's truncation rule;
                // normal names and the full 36-character pane ID must fit at 420 pt.
                if name == "long-branch", row.id == "branch" { continue }
                let value = try #require(frames["\(row.id).text"])
                #expect(
                    value.width >= PaneIdentityCardFixture.naturalValueWidth(row),
                    "\(name) @ \(width): full \(row.id) must be visible")
            }
            let ink = try PaneManagementIdentityTestInk.ink(in: mounted.host, maximumX: nil)
            let innerRight = Int(width - 26) * (ink.width / Int(width))
            #expect(
                !ink.points.indices.contains { ink.points[$0] && $0 % ink.width >= innerRight },
                "\(name) @ \(width): foreground ink overflows the inner edge")
            let bitmap = try #require(mounted.host.bitmapImageRepForCachingDisplay(in: mounted.host.bounds))
            mounted.host.cacheDisplay(in: mounted.host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(Array(png), named: "\(name)-\(Int(width)).png")
        }
        #expect(Set(heights).count == 1, "Card height must be stable from 520 pt: \(heights)")
    }
}
