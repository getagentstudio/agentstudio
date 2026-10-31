import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI

/// App owns the focused card's registration without changing the shared input control or key policy.
struct PaneContextCardAnswerForm: View {
    let form: AskFormModel
    let draft: Binding<AskFormDraft>
    let controls: PaneContextPopoverControls
    let ownerPaneId: UUID
    let controlScope: String
    let onSubmit: @MainActor (AskFormDraft) -> Void
    @State private var keyboardToken: TransientKeyboardSurfaceToken?

    var body: some View {
        AskAnswerForm(
            form: form, draft: draft, submitControl: controls.submit, scope: controlScope,
            choicePrompt: controls.chooseOption, requiredField: controls.requiredField, onSubmit: onSubmit
        )
        .background {
            PaneContextCardTextFocusBridge(onFocusChanged: updateKeyboardFocus)
                .allowsHitTesting(false)
        }
        .onChange(of: atom(\.managementLayer).isActive) { _, active in
            if !active { unregisterKeyboardSurface() }
        }
        .onDisappear { unregisterKeyboardSurface() }
    }

    private func updateKeyboardFocus(_ focused: Bool) {
        guard focused, atom(\.managementLayer).isActive else {
            unregisterKeyboardSurface()
            return
        }
        guard keyboardToken == nil, let windowId = atom(\.windowLifecycle).preferredWorkspaceWindowId else { return }
        keyboardToken = atom(\.transientKeyboardSurface).present(
            .paneContextCardTextForm(paneId: ownerPaneId), workspaceWindowId: windowId)
    }

    private func unregisterKeyboardSurface() {
        guard let keyboardToken else { return }
        atom(\.transientKeyboardSurface).dismiss(keyboardToken)
        self.keyboardToken = nil
    }
}

private struct PaneContextCardTextFocusBridge: NSViewRepresentable {
    let onFocusChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PaneContextCardTextFocusView {
        let view = PaneContextCardTextFocusView()
        view.onFocusChanged = onFocusChanged
        return view
    }

    func updateNSView(_ view: PaneContextCardTextFocusView, context: Context) {
        view.onFocusChanged = onFocusChanged
        view.refreshFocus()
    }

    static func dismantleNSView(_ view: PaneContextCardTextFocusView, coordinator: ()) {
        view.retire()
        view.onFocusChanged = nil
    }
}

/// NSWindow documents firstResponder as KVO compliant. Its synchronous fact precedes the next key event.
private final class PaneContextCardTextFocusView: NSView {
    var onFocusChanged: (@MainActor (Bool) -> Void)?
    private var firstResponderObservation: NSKeyValueObservation?
    private var editorDelegateObservation: NSKeyValueObservation?
    private weak var observedEditor: NSTextView?
    private var reportedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retire()
        guard let window else { return }
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
        refreshFocus()
    }

    override func layout() {
        super.layout()
        refreshFocus()
    }

    func refreshFocus() {
        let editor = window?.firstResponder as? NSTextView
        // AppKit reuses the field editor; its owning field can change without a new responder object.
        if observedEditor !== editor {
            editorDelegateObservation?.invalidate()
            observedEditor = editor
            editorDelegateObservation = editor?.observe(\.delegate, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            }
        }
        // The existing routing context owns workspace/key-window selection; this fact is scoped to this window's editor.
        guard let window, let editor, editor.isFieldEditor,
            let field = editor.delegate as? NSTextField, field.window === window,
            field.isEditable, !field.isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0
        else {
            reportFocus(false)
            return
        }
        // SwiftUI leaves native NSTextField identifiers empty. Scope its actual editor to this form's native bounds.
        let fieldFrame = convert(field.bounds, from: field)
        reportFocus(bounds.contains(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)))
    }

    func retire() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        editorDelegateObservation?.invalidate()
        editorDelegateObservation = nil
        observedEditor = nil
        reportFocus(false)
    }

    private func reportFocus(_ focused: Bool) {
        guard reportedFocus != focused else { return }
        reportedFocus = focused
        onFocusChanged?(focused)
    }
}
