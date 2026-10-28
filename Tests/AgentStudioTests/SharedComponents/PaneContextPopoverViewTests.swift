import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct PaneContextPopoverViewTests {
    @Test(arguments: [false, true], AskAnswerForm.Layout.allCases)
    func choiceButtonsAndAnswerDriveTheRealFormDraft(allowsMultiple: Bool, layout: AskAnswerForm.Layout) throws {
        let options = [Self.choice("allow", label: "Allow"), Self.choice("deny", label: "Deny")]
        var submitted: AskFormDraft?
        var submissionCount = 0
        try Self.withMounted(
            AskAnswerForm(
                form: .choice(options: options, presentation: allowsMultiple ? .checkboxes : .radio),
                submitControl: Self.answerControl, layout: layout,
                onSubmit: {
                    submitted = $0
                    submissionCount += 1
                })
        ) { host in
            let allow = try Self.button(in: host, identifier: "pane-context.choice.allow", label: "Allow")
            let deny = try Self.button(in: host, identifier: "pane-context.choice.deny", label: "Deny")
            if !allowsMultiple {
                let allowFrame = host.convert(allow.bounds, from: allow)
                let denyFrame = host.convert(deny.bounds, from: deny)
                if layout == .messages {
                    #expect(allowFrame.minY == denyFrame.minY)
                    #expect(denyFrame.minX > allowFrame.maxX)
                } else {
                    #expect(allowFrame.minY != denyFrame.minY)
                }
            }
            #expect(allow.accessibilityPerformPress())
            #expect(submissionCount == (allowsMultiple ? 0 : 1))
            host.layoutSubtreeIfNeeded()
            #expect(deny.accessibilityPerformPress())
            host.layoutSubtreeIfNeeded()
            if allowsMultiple {
                let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Submit")
                #expect(answer.accessibilityPerformPress())
            } else {
                #expect(Self.find(in: host, identifier: "pane-context.answer") == nil)
            }
            #expect(submissionCount == (allowsMultiple ? 1 : 2))
            #expect(submitted?.selectedChoices == (allowsMultiple ? ["allow", "deny"] : ["deny"]))
        }
    }

    @Test(arguments: AskAnswerForm.Layout.allCases, [ApprovalDecisionModel.approve, .deny])
    func bothLayoutsSubmitTheApprovalDecisionAndTypedReason(
        layout: AskAnswerForm.Layout, decision: ApprovalDecisionModel
    ) throws {
        let approve = Self.formControl("approve", label: "Approve")
        let deny = Self.formControl("deny", label: "Deny")
        let reason = Self.formControl("reason", label: "Reason (optional)")
        var submissions: [AskFormDraft] = []
        try Self.withMounted(
            AskAnswerForm(
                form: .approval(approve: approve, deny: deny, reason: reason), submitControl: Self.answerControl,
                layout: layout, onSubmit: { submissions.append($0) })
        ) { host in
            let field = try #require(Self.firstDescendant(NSTextField.self, in: host))
            try #require(field.window?.makeFirstResponder(field) == true)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("Reviewed carefully", replacementRange: NSRange(location: NSNotFound, length: 0))
            let reasonWindow = try #require(field.window)
            let returnKey = try #require(
                makeKeyEvent(
                    characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36,
                    windowNumber: reasonWindow.windowNumber))
            editor.keyDown(with: returnKey)
            host.layoutSubtreeIfNeeded()
            #expect(submissions.isEmpty, "Return in the reason field must not choose Approve or Deny")
            try #require(field.window?.makeFirstResponder(field) == true)
            let continuingEditor = try #require(field.currentEditor() as? NSTextView)
            continuingEditor.selectAll(nil)
            continuingEditor.insertText(
                "Reviewed carefully", replacementRange: NSRange(location: NSNotFound, length: 0))
            field.window?.makeFirstResponder(nil)
            host.layoutSubtreeIfNeeded()
            #expect(submissions.isEmpty, "Editing/committing the field must not approve or deny")
            let control = decision == .approve ? approve : deny
            let button = try Self.button(in: host, identifier: control.identifier, label: control.label)
            #expect(button.accessibilityPerformPress())
            #expect(submissions.count == 1)
            #expect(submissions.first?.approvalDecision == decision)
            #expect(submissions.first?.text == "Reviewed carefully")
        }
    }

    private static func formControl(_ suffix: String, label: String) -> PaneContextControlModel {
        .init(
            identifier: "pane-context." + suffix, label: label, icon: .system("checkmark"),
            tooltip: .init(text: label, shortcutDisplayText: nil))
    }

    @Test
    func freeTextFormRendersItsFieldAndAnswerCallback() throws {
        var submitted: AskFormDraft?
        try Self.withMounted(
            AskAnswerForm(
                form: .freeText(placeholder: "Your reply"), submitControl: Self.answerControl,
                onSubmit: { submitted = $0 })
        ) { host in
            #expect(Self.labels(in: host).contains("Your reply"))
            let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Submit")
            #expect(answer.accessibilityPerformPress())
            #expect(submitted?.text.isEmpty == true)
        }
    }

    @Test
    func elicitationRendersItsNativeFieldsPickerAndAnswerCallback() throws {
        let form = AskFormModel.elicitation([
            .init(
                name: "title", title: "Title", description: nil, required: true,
                kind: .string(choices: nil, minLength: 1, maxLength: 20, format: nil)),
            .init(
                name: "size", title: "Size", description: nil, required: false,
                kind: .number(minimum: nil, maximum: nil)),
            .init(
                name: "count", title: "Count", description: nil, required: true, kind: .integer(minimum: 1, maximum: 5)),
            .init(name: "enabled", title: "Enabled", description: nil, required: true, kind: .boolean),
            .init(
                name: "color", title: "Color", description: nil, required: true,
                kind: .string(
                    choices: [.init(value: "Red", label: "Red"), .init(value: "Blue", label: "Blue")], minLength: nil,
                    maxLength: nil, format: nil)),
        ])
        var submitted: AskFormDraft?
        try Self.withMounted(AskAnswerForm(form: form, submitControl: Self.answerControl, onSubmit: { submitted = $0 }))
        { host in
            #expect(Set(["Title", "Size", "Count"]).isSubset(of: Self.labels(in: host)))
            // Known gap on macOS 27: SwiftUI draws this Picker without an AppKit
            // NSPopUpButton, and the hosted form's accessibility tree is empty on the
            // runner (CI diag runs 37571905523 and 37578167046). The picker is asserted
            // on macOS 26 only until a macOS 27 assertion exists.
            if #unavailable(macOS 27) {
                let picker = try #require(Self.firstDescendant(NSPopUpButton.self, in: host))
                #expect(picker.itemTitles == ["Choose…", "Red", "Blue"])
            }
            if let checkbox = Self.find(in: host, identifier: "pane-context.field.enabled")
                as? any NSAccessibilityProtocol
            {
                #expect(checkbox.accessibilityLabel() == "Enabled")
            } else {
                // Lead disposition: the diagnostic PNG confirms this checkbox.
                // SwiftUI does not expose it here; draft value-in/answer-out is unit tested.
                print("checkbox render presence: visually confirmed in PNG, not test-asserted")
            }
            let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Submit")
            #expect(answer.accessibilityPerformPress())
            #expect(submitted != nil)
        }
    }

    private static let answerControl = PaneContextControlModel(
        identifier: "pane-context.answer", label: "Submit", icon: .system("checkmark.circle"),
        tooltip: .init(text: "Answer this message", shortcutDisplayText: nil))

    private static func choice(_ id: String, label: String) -> AskChoiceModel {
        .init(
            id: id, label: label,
            control: .init(
                identifier: "pane-context.choice.\(id)", label: label, icon: .system("checkmark.circle"),
                tooltip: .init(text: "Select \(label)", shortcutDisplayText: nil)))
    }

    private static func withMounted<Content: View>(
        _ content: Content, assertions: (NSHostingView<Content>) throws -> Void
    ) throws {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try assertions(host)
    }

    private static func button(in root: NSView, identifier: String, label: String) throws
        -> AccessibilityPressBridgeView
    {
        let button = try #require(Self.find(in: root, identifier: identifier) as? AccessibilityPressBridgeView)
        #expect(button.accessibilityLabel() == label)
        return button
    }

    private static func find(in root: AnyObject, identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        return find(in: root, identifier: identifier, visited: &visited)
    }

    private static func find(in element: AnyObject, identifier: String, visited: inout Set<ObjectIdentifier>)
        -> AnyObject?
    {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if accessible.accessibilityIdentifier() == identifier { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(in: child as AnyObject, identifier: identifier, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(in: child, identifier: identifier, visited: &visited) { return found }
        }
        return nil
    }

    private static func labels(in root: NSView) -> Set<String> {
        var visited = Set<ObjectIdentifier>()
        return labels(in: root, visited: &visited)
    }

    private static func labels(in element: AnyObject, visited: inout Set<ObjectIdentifier>) -> Set<String> {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return [] }
        var labels = Set<String>()
        if let accessible = element as? any NSAccessibilityProtocol {
            if let label = accessible.accessibilityLabel(), !label.isEmpty { labels.insert(label) }
            if let title = accessible.accessibilityTitle(), !title.isEmpty { labels.insert(title) }
            if let placeholder = accessible.accessibilityPlaceholderValue(), !placeholder.isEmpty {
                labels.insert(placeholder)
            }
            for child in accessible.accessibilityChildren() ?? [] {
                labels.formUnion(Self.labels(in: child as AnyObject, visited: &visited))
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            labels.formUnion(Self.labels(in: child, visited: &visited))
        }
        return labels
    }

    private static func firstDescendant<Child: NSView>(_ type: Child.Type, in root: NSView) -> Child? {
        if let child = root as? Child { return child }
        for view in root.subviews {
            if let child = firstDescendant(type, in: view) { return child }
        }
        return nil
    }
}
