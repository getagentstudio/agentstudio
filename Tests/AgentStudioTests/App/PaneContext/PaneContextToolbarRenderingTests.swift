import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct PaneContextToolbarRenderingTests {
    @Test("Agent Line uses the sidebar's keyed source and leaves both button groups fixed", arguments: [480.0, 1000.0])
    func agentLineOnlyUsesRemainingWidth(width: Double) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let statuses = SessionStatusAtom()
            statuses.apply([pane: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation, pane: { _ in nil })
            var baseline: [String: CGRect]?
            var baselineHeight: CGFloat?
            var emptyTextPixels: Data?
            var fixedGroupPixels: [Data]?
            var emptyBeyondCapPixels: Data?
            for summary in [
                nil, "Checking toolbar spacing", String(repeating: "W", count: 200),
                String(repeating: "Wide agent work description ", count: 20),
            ] {
                let line = summary.map {
                    AgentLineDetail(
                        summary: $0, refs: [], writer: .pane(pane),
                        updatedAt: .distantPast)
                }
                atoms.paneContextPresentation.apply([
                    pane: .set(
                        .init(
                            revision: .init(1), agentTitle: nil, agentLine: line, own: .zero,
                            includingDrawers: .zero, pullRequests: .notApplicable))
                ])
                try await withMountedToolbar(pane: pane, readers: readers, width: width) { mounted in
                    let controls = buttonFrames(in: mounted.host)
                    let barHeight = mounted.host.bounds.height
                    #expect(barHeight == DrawerLayout.iconStripHeight)
                    #expect(mounted.host.fittingSize.height == barHeight)
                    if let baselineHeight { #expect(barHeight == baselineHeight) } else { baselineHeight = barHeight }
                    #expect(controls.count == 9)
                    #expect(controls.values.allSatisfy { $0.width > 0 && $0.height > 0 })
                    if let baseline { #expect(controls == baseline) } else { baseline = controls }
                    let leadingIdentifiers: Set<String> = [
                        "paneSurfaceToolbar.drawerToggle", "paneSurfaceToolbar.drawerAdd",
                        "paneSurfaceToolbar.pinPane", "paneSurfaceToolbar.note",
                    ]
                    let middleStart = try #require(
                        controls.filter { leadingIdentifiers.contains($0.key) }.values.map(\.maxX).max())
                    let middleEnd = try #require(
                        controls.filter { !leadingIdentifiers.contains($0.key) }.values.map(\.minX).min())
                    let textStart =
                        middleStart + AppStyles.Shell.DrawerToolbar.trailingClusterSpacing
                        + AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth
                        + AppStyles.Shell.Sidebar.groupIconTitleSpacing
                    let textRect = CGRect(x: textStart, y: 0, width: middleEnd - textStart, height: barHeight)
                    #expect(textRect.width > 0)
                    let textPixels = try pixels(in: mounted.host, rect: textRect)
                    let groupPixels = try [
                        pixels(in: mounted.host, rect: CGRect(x: 0, y: 0, width: middleStart, height: barHeight)),
                        pixels(
                            in: mounted.host,
                            rect: CGRect(x: middleEnd, y: 0, width: width - middleEnd, height: barHeight)),
                    ]
                    let capEnd = min(
                        middleEnd, middleStart + 360 + AppStyles.Shell.DrawerToolbar.trailingClusterSpacing)
                    let beyondCapPixels =
                        middleEnd > capEnd
                        ? try pixels(
                            in: mounted.host,
                            rect: CGRect(x: capEnd, y: 0, width: middleEnd - capEnd, height: barHeight))
                        : Data()
                    if summary != nil {
                        #expect(
                            textPixels != (try #require(emptyTextPixels)), "Agent Line text must paint in the middle")
                        #expect(
                            groupPixels == (try #require(fixedGroupPixels)), "Agent Line must not paint over controls")
                        #expect(
                            beyondCapPixels == (try #require(emptyBeyondCapPixels)),
                            "Agent Line ink must stop at 360 points")
                    } else {
                        emptyTextPixels = textPixels
                        fixedGroupPixels = groupPixels
                        emptyBeyondCapPixels = beyondCapPixels
                    }
                    let labels = accessibilityLabels(in: mounted.host)
                    #expect(!labels.contains("Working"))
                    #expect(
                        !labels.contains(where: { $0.contains("Messages unavailable") || $0.contains("credential") }))
                    if let summary {
                        #expect(labels.contains(summary))
                    } else {
                        #expect(!labels.contains("Checking toolbar spacing"))
                    }
                    #expect(abs(mounted.host.bounds.width - CGFloat(width)) < 0.5)
                    #expect(mounted.host.fittingSize.width <= width)
                }
            }
            atoms.paneContextPresentation.remove([pane])
        }
    }

    @Test("a card with no activity still paints the sidebar clock chip")
    func cardPaintsUnknownActivityClock() throws {
        let context = PaneManagementContext(
            paneId: UUIDv7.generate(), identityRows: [], statusChips: nil,
            targetPath: nil, showsIdentityBlock: true)
        let loader = makeTestOcticonLoader()
        let mounted = mountCard(
            AnyView(ManagementPaneIdentityStrip(context: context, octiconLoader: loader)), width: 1000)
        defer { mounted.window.orderOut(nil) }
        let reference = mountCard(
            AnyView(
                SidebarChip(icon: .system(.clock), octiconLoader: loader, text: "—", style: .neutral)),
            width: nil)
        defer { reference.window.orderOut(nil) }
        let referenceInk = try ink(in: reference.host, minimumBrightness: 80)
        #expect(referenceInk.mask.contains(true), "The independent clock reference must paint")
        #expect(
            containsTextInk(referenceInk, in: try ink(in: mounted.host, minimumBrightness: 80)),
            "The card must paint the same clock and unknown-activity text as the sidebar")
    }

    @Test(
        "extracting activity chips leaves the sidebar row pixels unchanged",
        arguments: [false, true],
        [RepoExplorerPaneRecencyTier.strongBlue, .mediumBlue, .mutedBlue, .faintBlue, .grey])
    func sidebarActivityPixelsRemainUnchanged(isActive: Bool, tier: RepoExplorerPaneRecencyTier)
        throws
    {
        let loader = makeTestOcticonLoader()
        let actual = mountCard(
            AnyView(
                RepoExplorerPaneRowContent(
                    primaryText: "Terminal", secondaryLine: nil, branchContextText: nil, branchStatus: nil,
                    recencyText: "12m", recencyTier: tier, isActive: isActive,
                    isDrawerPane: false, octiconLoader: loader)), width: 420)
        defer { actual.window.orderOut(nil) }
        // Frozen from the pre-extraction row at 8c5fef8bc; no call to the extracted renderer.
        let reference = mountCard(
            AnyView(
                VStack(alignment: .leading, spacing: AppStyles.Shell.Sidebar.rowContentSpacing) {
                    RepoExplorerPaneTitleLineView(
                        text: "Terminal", isDrawerPane: false, octiconLoader: loader)
                    SidebarStatusChipRow(isPendingPullRequestFacts: false) {
                        RepoExplorerPaneChipOverflow { _ in
                            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                                SidebarChip(
                                    icon: .system(.clock), octiconLoader: loader, text: "12m",
                                    style: frozenRecencyStyle(tier))
                                if isActive {
                                    SidebarChip(
                                        icon: .system(.playCircleFill), octiconLoader: loader,
                                        text: nil, style: .accent(.accentColor))
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 0)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ), width: 420)
        defer { reference.window.orderOut(nil) }
        #expect(actual.host.bounds == reference.host.bounds)
        #expect(try pixels(in: actual.host) == pixels(in: reference.host))
    }

    private func frozenRecencyStyle(_ tier: RepoExplorerPaneRecencyTier) -> SidebarChip.Style {
        switch tier {
        case .strongBlue: .accent(AppStyles.Shell.Sidebar.chipInfoColor)
        case .mediumBlue: .accent(AppStyles.Shell.Sidebar.recencyMediumBlue)
        case .mutedBlue: .accent(AppStyles.Shell.Sidebar.recencyMutedBlue)
        case .faintBlue: .accent(AppStyles.Shell.Sidebar.recencyFaintBlue)
        case .grey: .neutral
        }
    }

    @Test("lineless cards paint complete identity values", arguments: [1340.0, 2000.0])
    func cardDoesNotTruncateIdentities(width: Double) throws {
        let pane = try #require(UUID(uuidString: "01A15E24-74DE-761D-A3FA-959D7FBCA58C"))
        let rows: [PaneManagementIdentityRow] = [
            .init(id: "repo", icon: .system("folder"), text: "alpha-repo", toolTip: nil),
            .init(id: "worktree", icon: .system("folder"), text: "alpha-repo", toolTip: nil),
            .init(id: "branch", icon: .system("folder"), text: "main", toolTip: nil),
            .init(id: "cwd", icon: .system("folder"), text: "alpha-repo", toolTip: nil),
            .init(
                id: "session", icon: .system("folder"), text: "codex · known-conversation", toolTip: nil,
                copyValue: "known-conversation"),
            .init(id: "pane", icon: .system("folder"), text: pane.uuidString, toolTip: nil, copyValue: pane.uuidString),
        ]
        let context = PaneManagementContext(
            paneId: pane, identityRows: rows, statusChips: nil, targetPath: nil, showsIdentityBlock: true)
        let mounted = mountCard(
            AnyView(ManagementPaneIdentityStrip(context: context, octiconLoader: makeTestOcticonLoader())), width: width
        )
        defer { mounted.window.orderOut(nil) }
        let rendered = try ink(in: mounted.host)
        for row in rows {
            let reference = mountCard(
                AnyView(
                    Text(row.text)
                        .font(
                            .system(
                                size: AppStyles.Shell.Sidebar.branchFontSize, weight: .medium,
                                design: row.id == "pane" ? .monospaced : .default)
                        )
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize()
                ), width: nil)
            defer { reference.window.orderOut(nil) }
            #expect(
                containsTextInk(try ink(in: reference.host), in: rendered),
                "Complete \(row.id) value must be visibly rendered at \(width) points")
        }
    }

    func mountCard(_ content: AnyView, width: CGFloat?) -> PaneContextToolbarTestHost {
        let host = NSHostingView(
            rootView: AnyView(content.frame(width: width).background(Color.black).environment(\.colorScheme, .dark)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return PaneContextToolbarTestHost(host: host, window: window)
    }

    func ink(in host: NSView, minimumBrightness: UInt8 = 160) throws -> (width: Int, height: Int, mask: [Bool]) {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let mask = stride(from: 0, to: bytes.count, by: 4).map {
            bytes[$0] > minimumBrightness && bytes[$0 + 1] > minimumBrightness && bytes[$0 + 2] > minimumBrightness
        }
        return (image.width, image.height, mask)
    }

    func containsTextInk(
        _ reference: (width: Int, height: Int, mask: [Bool]),
        in rendered: (width: Int, height: Int, mask: [Bool])
    ) -> Bool {
        let points = reference.mask.indices.filter { reference.mask[$0] }.map {
            (x: $0 % reference.width, y: $0 / reference.width)
        }
        guard !points.isEmpty, reference.width <= rendered.width, reference.height <= rendered.height else {
            return false
        }
        // Text can land on a different subpixel phase in the grid than in its intrinsic-width reference.
        // Allow one raster pixel around each stroke, while requiring almost the entire full value.
        let allowedMisses = points.count / 20
        let firstPoint = points[0]
        for originY in 0...(rendered.height - reference.height) {
            for originX in 0...(rendered.width - reference.width) {
                guard rendered.mask[(originY + firstPoint.y) * rendered.width + originX + firstPoint.x] else {
                    continue
                }
                var misses = 0
                for point in points {
                    let pixelX = originX + point.x
                    let pixelY = originY + point.y
                    let matches = (-1...1).contains { deltaY in
                        (-1...1).contains { deltaX in
                            let x = pixelX + deltaX
                            let y = pixelY + deltaY
                            return x >= 0 && x < rendered.width && y >= 0 && y < rendered.height
                                && rendered.mask[y * rendered.width + x]
                        }
                    }
                    if !matches {
                        misses += 1
                        if misses > allowedMisses { break }
                    }
                }
                if misses <= allowedMisses { return true }
            }
        }
        return false
    }

    @Test("the toolbar Agent Line is absent without a display, even with Working and a credential refusal")
    func missingDisplayKeepsMiddleEmpty() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let statuses = SessionStatusAtom()
            statuses.apply([pane: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation, pane: { _ in nil })
            try await withMountedToolbar(pane: pane, readers: readers, width: 480) { mounted in
                let warningPixels = try pixels(in: mounted.host)
                statuses.apply([pane: .remove])
                try await withMountedToolbar(pane: pane, readers: readers, width: 480) { baseline in
                    let baselinePixels = try pixels(in: baseline.host)
                    #expect(warningPixels == baselinePixels)
                    let labels = accessibilityLabels(in: mounted.host)
                    #expect(!labels.contains("Working"))
                    #expect(
                        !labels.contains(where: { $0.contains("Messages unavailable") || $0.contains("credential") }))
                    #expect(buttonFrames(in: mounted.host).count == 9)
                }
            }
        }
    }

    @Test("the card keeps sidebar lines, known identities and omits unknown Git placeholders")
    func cardMatchesSidebarInformation() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Proof terminal")
            let paneId = PaneId(existingUUID: pane.id)
            let statuses = SessionStatusAtom()
            statuses.apply([paneId: .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized))])
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) })
            let session = SessionSummary(
                id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("known-conversation"),
                bindingGeneration: UUIDv7.generate(), status: .working(.active), providerPrompts: [])
            let projected = PaneManagementContext.project(paneId: pane.id, store: store)
                .includingVerifiedLiveSession(session)
            let context = PaneManagementContext(
                paneId: pane.id, identityRows: projected.identityRows,
                statusChips: .init(branchStatus: .unknown), targetPath: nil, showsIdentityBlock: true)
            let input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)
            let lines = await PaneManagementIdentityCapture.lines(input, now: .distantPast)
            #expect(
                lines.contains(.sessionStatus(try #require(RepoExplorerPaneContextLine.session(.working(.active))))))
            #expect(lines.contains(.connectionIssue(.connection(.credentialNotRecognized))))
            #expect(!SidebarGitStatusChips.hasContent(branchStatus: .unknown, usesPanesLoadingChip: true))
            for width in [420.0, 1000.0] {
                let host = NSHostingView(
                    rootView:
                        ManagementPaneIdentityStrip(
                            context: context, octiconLoader: makeTestOcticonLoader(), lines: lines
                        )
                        .frame(width: width))
                host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                let window = NSWindow(
                    contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                defer { window.orderOut(nil) }
                let labels = accessibilityLabels(in: host)
                #expect(labels.contains(where: { $0.contains("Working") }))
                #expect(
                    labels.contains(where: { $0.contains("Messages unavailable · restart this shell to reconnect") }))
                #expect(labels.contains(where: { $0.contains("Pane \(pane.id.uuidString)") }))
                #expect(labels.contains(where: { $0.contains("Session codex · known-conversation") }))
                #expect(!labels.contains(where: { $0.contains("credentialNotRecognized") || $0.contains("?") }))
                #expect(host.fittingSize.width <= width)
            }
        }
    }

    func withMountedToolbar(
        pane: PaneId, readers: PaneContextUIReaders, width: CGFloat,
        body: (PaneContextToolbarTestHost) async throws -> Void
    ) async throws {
        let mounted = try await mount(pane: pane, readers: readers, width: width)
        do {
            try await body(mounted)
            try await mounted.stop()
        } catch {
            mounted.hide()
            try? await mounted.clock?.retire()
            try? await mounted.clock?.facts.finish()
            mounted.window.close()
            throw error
        }
    }

    private func mount(pane: PaneId, readers: PaneContextUIReaders, width: CGFloat) async throws
        -> PaneContextToolbarTestHost
    {
        let clock = NativeCardTestClock()
        let hasLine = readers.contextDisplayForPane(pane)?.agentLine != nil
        let loader = makeTestOcticonLoader()
        let trailing = DrawerOverlay.TrailingActions(
            editPaneNoteAction: action(.editPaneNote), openEditorMenuAction: action(.openPaneLocationInEditorMenu),
            openFinderAction: action(.openPaneLocationInFinder), copyPathAction: action(.copyCurrentPanePath),
            gitStatusPresentation: .resolve(
                branchStatus: .init(
                    isDirty: true, syncState: .unknown, prCount: 1, linesAdded: 0, linesDeleted: 0,
                    untrackedFileCount: 1)),
            openPullRequestAction: surfaceAction(.openPullRequest),
            editorMenuContent: AnyView(EmptyView()), editorMenuPresented: .constant(false), buttonTitle: nil
        ).withPaneContextContent(
            AnyView(
                PaneContextToolbarControls(paneId: pane, readers: readers, octiconLoader: loader, onGoToPane: { _ in }))
        )
        let host = NSHostingView(
            rootView: AnyView(
                DrawerIconBar(
                    octiconLoader: loader,
                    leadingControls: .drawer(
                        isExpanded: false, addDrawerPaneAction: action(.addDrawerPane),
                        toggleDrawerAction: action(.toggleDrawer)),
                    pinPaneAction: action(.pinPane), trailingActions: trailing,
                    paneContextActions: [surfaceAction(.zoomPane)],
                    middleContent: AnyView(
                        PaneContextToolbarAgentLine(
                            paneId: pane, readers: readers, octiconLoader: loader, clock: clock,
                            wallNow: Date(timeIntervalSince1970: 1_800_000_125),
                            onRelativeTimeEvent: { clock.observeOwner($0) }))
                ).frame(width: width).environment(\.colorScheme, .dark)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mounted = PaneContextToolbarTestHost(
            host: host, window: window, clock: clock, paneId: pane.uuid, hasLine: hasLine)
        do {
            if hasLine {
                try #require(try await clock.nextOperation(pane: pane.uuid, input: nil) == .started)
                try await clock.entered(pane: pane.uuid, input: nil)
                let fact = try await clock.facts.expectNext(
                    in: 0, where: { _ in true }, "toolbar age registration or worker end")
                guard case .registered = fact else {
                    throw ToolbarHostFailure.unexpectedClockFact(String(describing: fact))
                }
            } else {
                #expect(try await clock.nextHideResult() == .notRunning)
            }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return mounted
        } catch {
            mounted.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            window.close()
            throw error
        }
    }

    private func action(_ command: AppCommand) -> TargetedCommandControlAction {
        .init(commandSpec: command.definition, isEnabled: true, perform: {})
    }

    private func surfaceAction(_ command: AppCommand) -> PaneSurfaceToolbarAction {
        let spec = command.definition
        return .init(
            state: .init(
                label: spec.label, accessibilityIdentifier: "proof.\(command.rawValue)", icon: spec.icon,
                tooltip: spec.controlTooltipRenderValue(), isEnabled: true, isSelected: false), perform: {})
    }

    func pixels(in host: NSView, rect: CGRect? = nil) throws -> Data {
        let region = rect ?? host.bounds
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
        host.cacheDisplay(in: region, to: bitmap)
        // PNGs embed the display ICC profile's creation time. Compare exact rendered pixels,
        // normalized to sRGB RGBA, so crossing a wall-clock second cannot change equality.
        let image = try #require(bitmap.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    func buttonFrames(in host: NSView) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let button = view as? AccessibilityPressBridgeView {
                frames[button.accessibilityIdentifier()] = host.convert(button.bounds, from: button)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }

    func accessibilityLabels(in view: NSView) -> Set<String> {
        var labels = Set<String>()
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: labelSelector),
                let label = object.perform(labelSelector)?.takeUnretainedValue() as? String
            {
                labels.insert(label)
            }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
                let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject]
            {
                children.forEach(visit)
            }
            if let nativeView = object as? NSView { nativeView.subviews.forEach(visit) }
        }
        visit(view)
        return labels
    }
}
