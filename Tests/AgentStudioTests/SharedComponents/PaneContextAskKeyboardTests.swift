import AgentStudioInfrastructure
import AppKit
import Observation
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Native keys in multiple ask forms", .serialized)
struct PaneContextAskKeyboardTests {
    @Test("F6 non-text Return cannot submit either of two eligible drafts", arguments: AskAnswerForm.Layout.allCases)
    func nonTextReturnDoesNotChooseAForm(layout: AskAnswerForm.Layout) throws {
        let state = KeyboardDrafts()
        state.first.text = "First eligible reply"
        state.second.text = "Second eligible reply"
        try withForms(.freeText(placeholder: "Reply"), layout: layout, state: state) { host, window in
            try #require(window.makeFirstResponder(window))
            try sendReturn(window)
            host.layoutSubtreeIfNeeded()
            #expect(state.submissions.isEmpty, "Return outside text/focused Submit cannot choose an arbitrary ask")
        }
    }

    @Test("F6 a native single-line Return submits only the focused field's ask")
    func singleLineReturnSubmitsOnlyItsOwnAsk() throws {
        let state = KeyboardDrafts()
        state.first.fields["value"] = "First eligible reply"
        let form = AskFormModel.elicitation([
            .init(
                name: "value", title: "Reply", description: nil, required: true,
                kind: .string(choices: nil, minLength: 1, maxLength: nil, format: nil))
        ])
        try withForms(form, layout: .messages, state: state) { host, window in
            let fields = editableFields(host)
            try #require(fields.count == 2, "Both real single-line controls must be mounted")
            let field = fields[1]
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("Second focused reply", replacementRange: editor.selectedRange())
            host.layoutSubtreeIfNeeded()
            try #require(state.second.fields["value"] == "Second focused reply")
            try #require(state.first.fields["value"] == "First eligible reply")
            try sendReturn(window)
            host.layoutSubtreeIfNeeded()
            #expect(state.submissions.map(\.key) == ["second"])
            #expect(state.submissions.first?.draft.fields["value"] == "Second focused reply")
        }
    }

    @Test(
        "F6 plain and Shift-Return in vertical free text never submit or invoke a callback",
        arguments: AskAnswerForm.Layout.allCases, [false, true])
    func multilineReturnDoesNotSubmit(layout: AskAnswerForm.Layout, shift: Bool) throws {
        let state = KeyboardDrafts()
        state.second.text = "Another eligible reply"
        try withForms(.freeText(placeholder: "Reply"), layout: layout, state: state) { host, window in
            let fields = editableFields(host)
            try #require(fields.count == 2, "Both real multiline controls must be mounted")
            let field = fields[0]
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("Keep editing", replacementRange: editor.selectedRange())
            host.layoutSubtreeIfNeeded()
            try #require(state.first.text == "Keep editing")
            try #require(state.submissions.isEmpty)
            try sendReturn(window, modifiers: shift ? [.shift] : [])
            host.layoutSubtreeIfNeeded()
            #expect(state.submissions.isEmpty, "A native multiline edit must not activate another form's Submit")
        }
    }

    private func withForms(
        _ form: AskFormModel, layout: AskAnswerForm.Layout, state: KeyboardDrafts,
        body: (NSView, NSWindow) throws -> Void
    ) throws {
        let content = VStack {
            AskAnswerForm(
                form: form, draft: state.binding(first: true), submitControl: submit, scope: "first", layout: layout
            ) {
                state.submissions.append(.init(key: "first", draft: $0))
            }
            AskAnswerForm(
                form: form, draft: state.binding(first: false), submitControl: submit, scope: "second", layout: layout
            ) {
                state.submissions.append(.init(key: "second", draft: $0))
            }
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content)
        host.frame = .init(x: 0, y: 0, width: 480, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try body(host, window)
    }

    private func sendReturn(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: modifiers, characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36,
                windowNumber: window.windowNumber))
        NSApp.sendEvent(event)
    }

    private func editableFields(_ root: NSView) -> [NSTextField] {
        let own = (root as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + root.subviews.flatMap { editableFields($0) }
    }

    private var submit: PaneContextControlModel {
        .init(
            identifier: "pane-context.submit", label: "Submit", icon: .system("checkmark"),
            tooltip: .init(text: "Submit", shortcutDisplayText: nil))
    }
}

@MainActor @Observable
private final class KeyboardDrafts {
    struct Submission {
        let key: String
        let draft: AskFormDraft
    }
    var first = AskFormDraft()
    var second = AskFormDraft()
    @ObservationIgnored var submissions: [Submission] = []

    func binding(first isFirst: Bool) -> Binding<AskFormDraft> {
        .init(
            get: { isFirst ? self.first : self.second },
            set: {
                if isFirst { self.first = $0 } else { self.second = $0 }
            })
    }
}
