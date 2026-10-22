import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityGeometryTests {
    @Test(arguments: PaneIdentityCardFixture.names)
    func fieldListKeepsItsOrderAlignmentAndFullIdentityAtEveryWidth(name: String) throws {
        let strip = try PaneIdentityCardFixture.strip(name)
        let model = ManagementPaneIdentityPresentation(context: strip.context, lines: strip.lines)
        var fixedHeights = Set<CGFloat>()
        var titleHeights = Set<CGFloat>()
        var messageHeights = Set<CGFloat>()
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
            try PaneIdentityCardFixture.expectContained(in: mounted.host)
            let frames = PaneIdentityCardFixture.frames(in: mounted.host)
            let titleHeight = try #require(frames["title"]).height
            let messageHeight = frames["agentLine"]?.height ?? 0
            titleHeights.insert(titleHeight)
            messageHeights.insert(messageHeight)
            fixedHeights.insert(mounted.host.fittingSize.height - titleHeight - messageHeight)
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
        #expect(fixedHeights.count == 1, "Only wrapped title/message lines may change the card height")
        expectWholeLineChanges(titleHeights, font: .system(size: 13, weight: .semibold))
        expectWholeLineChanges(messageHeights, font: .system(size: 12))
    }
    @Test func captionsAlignAcrossAllCardsAndCopyFollowsTheValue() throws {
        var valueOrigins = Set<CGFloat>()
        for name in PaneIdentityCardFixture.names {
            let strip = try PaneIdentityCardFixture.strip(name)
            for width in PaneIdentityCardFixture.widths {
                let mounted = PaneIdentityCardFixture.mount(strip, width: width)
                defer {
                    mounted.window.contentView = nil
                    mounted.window.close()
                }
                let frames = PaneIdentityCardFixture.frames(in: mounted.host)
                valueOrigins.insert(try #require(frames["pane.text"]).minX)
                let caption = try #require(frames["pane.caption"])
                let reference = PaneIdentityCardFixture.mountView(
                    AnyView(
                        Text("WORKTREE").font(.system(size: 11, weight: .semibold)).fixedSize()
                            .background {
                                AccessibilityLabelBridge(identifier: "paneManagement.card.reference", label: "")
                            }), width: width)
                defer {
                    reference.window.contentView = nil
                    reference.window.close()
                }
                #expect(caption.width == PaneIdentityCardFixture.frames(in: reference.host)["reference"]?.width)
                for row in strip.context.identityRows where ["pane", "session"].contains(row.id) {
                    let text = try #require(frames["\(row.id).text"])
                    let copy = try #require(frames["\(row.id).copy"])
                    #expect(copy.minX - text.maxX == 4, "Copy must follow the value at the shell's small gap")
                    if width == 1000 {
                        #expect(
                            text.width == PaneIdentityCardFixture.naturalValueWidth(row),
                            "\(name): text must keep its natural width so the copy button stays inline")
                    }
                }
            }
        }
        #expect(valueOrigins.count == 1, "Every card must use the full caption set: \(valueOrigins)")
    }

    @Test func identityFieldsRenderTheirDistinctProducerIcons() throws {
        let strip = try PaneIdentityCardFixture.strip("session-where")
        let expected: [(String, PaneManagementIcon)] = [
            ("repo", .octicon("octicon-repo")), ("branch", .octicon("octicon-git-branch")),
            ("worktree", .octicon("octicon-git-worktree")), ("cwd", .system("folder")),
            ("session", .system("person.crop.circle")), ("pane", .system("terminal")),
        ]
        let mounted = PaneIdentityCardFixture.mount(strip, width: 420)
        defer {
            mounted.window.contentView = nil
            mounted.window.close()
        }
        let frames = PaneIdentityCardFixture.frames(in: mounted.host)
        var distinctGlyphs = Set<String>()
        for (identifier, icon) in expected {
            #expect(strip.context.identityRows.first { $0.id == identifier }?.icon == icon)
            let bounds = try #require(frames["\(identifier).icon"])
            let glyph = try PaneManagementIdentityTestInk.ink(in: mounted.host, maximumX: nil, bounds: bounds)
            let indices = glyph.points.indices.filter { glyph.points[$0] }
            let left = try #require(indices.map { $0 % glyph.width }.min(), "\(identifier) must have visible ink")
            let right = try #require(indices.map { $0 % glyph.width }.max())
            let top = try #require(indices.map { $0 / glyph.width }.min())
            let bottom = try #require(indices.map { $0 / glyph.width }.max())
            let signature = (top...bottom).map { row in
                (left...right).map { glyph.points[row * glyph.width + $0] ? "1" : "0" }.joined()
            }.joined(separator: "\n")
            distinctGlyphs.insert(signature)
        }
        #expect(distinctGlyphs.count == expected.count, "Each field must paint its own distinct producer glyph")
    }

    private func expectWholeLineChanges(_ heights: Set<CGFloat>, font: Font) {
        #expect(heights.count <= 2, "A two-line field has at most two natural heights")
        if heights.count == 2, let minimum = heights.min(), let maximum = heights.max() {
            let oneLine = NSHostingView(rootView: Text("Line").font(font).fixedSize()).fittingSize.height
            let twoLines = NSHostingView(rootView: Text("Line\nLine").font(font).fixedSize()).fittingSize.height
            #expect(maximum - minimum == twoLines - oneLine, "Height must change by one whole wrapped line")
        }
    }

}
