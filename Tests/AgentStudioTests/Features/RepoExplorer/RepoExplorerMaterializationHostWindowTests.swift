import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
private final class RowlessWindowContentChild: RepoExplorerMaterializationContentChild {
    let view = NSView()

    func apply(
        _ candidate: RepoExplorerMaterializationContentCandidate,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        completion(.accepted)
    }

    func prepareForRemoval(
        visibleGeneration: UInt64,
        completion: @escaping (RepoExplorerMaterializationChildDisposition) -> Void
    ) {
        completion(.accepted)
    }

    func applySelection(rowID: RepoExplorerRowID?, scrollIntoView: Bool) -> Bool {
        _ = rowID
        _ = scrollIntoView
        return true
    }

    func performListKeyboardEffect(_ effect: RepoExplorerListKeyboardEffect) {
        _ = effect
    }

    func suspendDemand() {}

    func resumeDemand(visibleGeneration: UInt64) {
        _ = visibleGeneration
    }

    func detach() {}
}

@MainActor
private final class ExternalSidebarTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite("Repo Explorer materialization host window", .serialized)
struct RepoExplorerMaterializationHostWindowTests {
    @Test("a real list responder ignores retired Space input")
    func realListResponderIgnoresRetiredSpaceInput() throws {
        var previewTargetChangeCount = 0
        let interaction = RepoExplorerKeyboardInteraction()
        interaction.configure(
            RepoExplorerKeyboardCallbacks(
                canInterpretListInput: { true },
                onSelectedPaneTargetChange: { _, _ in previewTargetChangeCount += 1 }
            )
        )
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        host.installKeyboardInteraction(interaction)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.detach()
            window.close()
        }
        #expect(window.makeFirstResponder(host))
        let callbackCountBeforeSpace = previewTargetChangeCount

        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        let repeatDown = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: true,
                keyCode: 49
            )
        )
        let up = try #require(
            NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )

        host.keyDown(with: down)
        host.keyDown(with: repeatDown)
        host.keyUp(with: up)
        #expect(previewTargetChangeCount == callbackCountBeforeSpace)
    }

    @Test("a modified retired Space key-up does not invoke preview")
    func realListResponderIgnoresModifiedRetiredSpaceKeyUp() throws {
        var previewTargetChangeCount = 0
        let interaction = RepoExplorerKeyboardInteraction()
        interaction.configure(
            RepoExplorerKeyboardCallbacks(
                canInterpretListInput: { true },
                onSelectedPaneTargetChange: { _, _ in previewTargetChangeCount += 1 }
            )
        )
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        host.installKeyboardInteraction(interaction)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.detach()
            window.close()
        }
        #expect(window.makeFirstResponder(host))
        let callbackCountBeforeSpace = previewTargetChangeCount

        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        let modifiedUp = try #require(
            NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [.shift],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )

        host.keyDown(with: down)
        host.suspendDemand()
        host.keyUp(with: modifiedUp)
        #expect(previewTargetChangeCount == callbackCountBeforeSpace)
    }

    @Test("Caps Lock Space remains a non-preview input")
    func capsLockSpaceRemainsNonPreviewInput() throws {
        var previewTargetChangeCount = 0
        let interaction = RepoExplorerKeyboardInteraction()
        interaction.configure(
            RepoExplorerKeyboardCallbacks(
                canInterpretListInput: { true },
                onSelectedPaneTargetChange: { _, _ in previewTargetChangeCount += 1 }
            )
        )
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        host.installKeyboardInteraction(interaction)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.detach()
            window.close()
        }
        #expect(window.makeFirstResponder(host))
        let callbackCountBeforeSpace = previewTargetChangeCount

        let capsLockDown = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.capsLock],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )

        host.keyDown(with: capsLockDown)
        #expect(previewTargetChangeCount == callbackCountBeforeSpace)
    }

    @Test("rowless sidebar host owns keyboard focus across empty result changes")
    func rowlessHostRetainsKeyboardFocusAcrossPresentationChanges() throws {
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.detach()
            window.close()
        }

        #expect(host.acceptsFirstResponder)
        #expect(window.makeFirstResponder(host))
        #expect(window.firstResponder === host)

        let baseline = try #require(host.acceptedBaseline)
        let presentation = RepoExplorerMaterializationPresentation.rowless(.noTabs)
        let plan = try RepoExplorerNativeUpdatePlan.validating(
            baseline: baseline,
            candidate: presentation,
            requestGeneration: 1
        ).get()
        let candidate = RepoExplorerMaterializationCandidate(
            id: RepoExplorerMaterializationCandidateID(rawValue: 1),
            lifetimeID: host.lifetimeID,
            demandEpoch: 1,
            requestGeneration: 1,
            visibleGeneration: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: presentation,
            nativeUpdatePlan: plan
        )

        guard case .accepted = host.apply(candidate) else {
            Issue.record("The empty presentation update must be accepted")
            return
        }
        #expect(window.firstResponder === host)
        #expect(host.presentedChildView?.accessibilityLabel() == "No tabs")
    }

    @Test(
        "rowless presentation fills a real window and exposes its accessibility label",
        arguments: RepoExplorerRowlessPresentation.allCases
    )
    func rowlessPresentationLayoutAndAccessibility(
        presentation: RepoExplorerRowlessPresentation
    ) throws {
        let expectedSize = NSSize(width: 320, height: 480)
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(
                rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
            ),
            initialDemandEpoch: 1,
            initialPresentation: presentation,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        defer { window.close() }

        let rowlessView = try #require(host.presentedChildView)
        #expect(host.frame.size == expectedSize)
        #expect(rowlessView.frame == host.bounds)
        #expect(rowlessView.isAccessibilityElement())
        #expect(rowlessView.accessibilityRole() == .group)
        #expect(rowlessView.accessibilityLabel() == presentation.accessibilityLabel)
        #expect(host.visibleGeneration == 0)
        #expect(host.isPresentationReady)
    }

    @Test("rowless updates preserve an existing first responder")
    func rowlessUpdatePreservesFirstResponder() throws {
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(
                rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
            ),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { RowlessWindowContentChild() },
            onFeedback: { _ in }
        )
        let focusView = ExternalSidebarTestResponder()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        container.addSubview(host)
        container.addSubview(focusView)
        host.frame = container.bounds
        focusView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        #expect(window.makeFirstResponder(focusView))

        let baseline = try #require(host.acceptedBaseline)
        let presentation = RepoExplorerMaterializationPresentation.rowless(.noTabs)
        let plan = try RepoExplorerNativeUpdatePlan.validating(
            baseline: baseline,
            candidate: presentation,
            requestGeneration: 1
        ).get()
        let candidate = RepoExplorerMaterializationCandidate(
            id: RepoExplorerMaterializationCandidateID(rawValue: 1),
            lifetimeID: host.lifetimeID,
            demandEpoch: 1,
            requestGeneration: 1,
            visibleGeneration: 1,
            expectedRevision: 0,
            proposedRevision: 1,
            presentation: presentation,
            nativeUpdatePlan: plan
        )
        guard case .accepted = host.apply(candidate) else {
            Issue.record("The rowless presentation update must be accepted")
            return
        }

        #expect(window.firstResponder === focusView)
        #expect(host.presentedChildView?.accessibilityLabel() == "No tabs")
    }
}
