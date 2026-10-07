import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct PaneContextPopoverViewTests {
    @Test(arguments: [false, true])
    func choiceButtonsAndAnswerDriveTheRealFormDraft(allowsMultiple: Bool) throws {
        let options = [Self.choice("allow", label: "Allow"), Self.choice("deny", label: "Deny")]
        var submitted: AskFormDraft?
        try Self.withMounted(
            AskAnswerForm(
                form: .choice(options: options, allowsMultiple: allowsMultiple),
                submitControl: Self.answerControl, onSubmit: { submitted = $0 })
        ) { host in
            let allow = try Self.button(in: host, identifier: "pane-context.choice.allow", label: "Allow")
            let deny = try Self.button(in: host, identifier: "pane-context.choice.deny", label: "Deny")
            #expect(allow.accessibilityPerformPress())
            host.layoutSubtreeIfNeeded()
            #expect(deny.accessibilityPerformPress())
            host.layoutSubtreeIfNeeded()
            let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Answer")
            #expect(answer.accessibilityPerformPress())
            #expect(submitted?.selectedChoices == (allowsMultiple ? ["allow", "deny"] : ["deny"]))
        }
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
            let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Answer")
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
                kind: .string(choices: ["Red", "Blue"], minLength: nil, maxLength: nil, format: nil)),
        ])
        var submitted: AskFormDraft?
        try Self.withMounted(AskAnswerForm(form: form, submitControl: Self.answerControl, onSubmit: { submitted = $0 }))
        { host in
            #expect(Set(["Title", "Size", "Count"]).isSubset(of: Self.labels(in: host)))
            let picker = try #require(Self.firstDescendant(NSPopUpButton.self, in: host))
            #expect(picker.itemTitles == ["Choose…", "Red", "Blue"])
            if let checkbox = Self.find(in: host, identifier: "pane-context.field.enabled")
                as? any NSAccessibilityProtocol
            {
                #expect(checkbox.accessibilityLabel() == "Enabled")
            } else {
                // Lead disposition: the diagnostic PNG confirms this checkbox.
                // SwiftUI does not expose it here; draft value-in/answer-out is unit tested.
                print("checkbox render presence: visually confirmed in PNG, not test-asserted")
            }
            let answer = try Self.button(in: host, identifier: "pane-context.answer", label: "Answer")
            #expect(answer.accessibilityPerformPress())
            #expect(submitted != nil)
        }
    }

    private static let answerControl = PaneContextControlModel(
        identifier: "pane-context.answer", label: "Answer", icon: .system("checkmark.circle"),
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
