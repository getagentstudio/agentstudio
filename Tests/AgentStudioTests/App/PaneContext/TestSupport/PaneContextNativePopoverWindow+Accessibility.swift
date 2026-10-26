import AppKit
import Foundation
import Testing

extension PaneContextNativePopoverWindow {
    var editableFields: [NSTextField] { roots.flatMap { descendants(NSTextField.self, in: $0) }.filter(\.isEditable) }
    var nativeButtons: [NSButton] { roots.flatMap { descendants(NSButton.self, in: $0) } }

    func typeText(placeholder: String, value: String) throws {
        let matches = editableFields.filter { $0.placeholderString == placeholder }
        try #require(
            matches.count == 1,
            "Expected one native field with placeholder \(placeholder); fields=\(editableFields.map { $0.placeholderString ?? "<nil>" })"
        )
        let field = matches[0]
        try #require(field.window?.makeFirstResponder(field) == true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        field.window?.makeFirstResponder(nil)
        #expect(field.stringValue == value)
        layout()
    }

    private func descendants<Child: NSView>(_ type: Child.Type, in root: NSView) -> [Child] {
        if let child = root as? Child { return [child] }
        return root.subviews.flatMap { descendants(type, in: $0) }
    }

    func find(_ identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        for root in roots {
            if let element = find(root, matching: { $0.accessibilityIdentifier() == identifier }, visited: &visited) {
                return element
            }
        }
        return nil
    }

    var popoverWindow: NSWindow? {
        NSApp.windows.first { $0 != window && $0.isVisible && $0.contentView != nil }
    }
    var roots: [NSView] { NSApp.windows.filter(\.isVisible).compactMap(\.contentView) }

    func labels() -> [String] {
        var visited = Set<ObjectIdentifier>()
        var result: [String] = []
        for root in roots { collectLabels(root, visited: &visited, result: &result) }
        return result
    }

    private func find(
        _ element: AnyObject, matching predicate: (any NSAccessibilityProtocol) -> Bool,
        visited: inout Set<ObjectIdentifier>
    ) -> AnyObject? {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if predicate(accessible) { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(child as AnyObject, matching: predicate, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(child, matching: predicate, visited: &visited) { return found }
        }
        return nil
    }

    private func collectLabels(_ element: AnyObject, visited: inout Set<ObjectIdentifier>, result: inout [String]) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        if let accessible = element as? any NSAccessibilityProtocol {
            if let label = accessible.accessibilityLabel(), !label.isEmpty { result.append(label) }
            if let value = accessible.accessibilityValue() as? String, !value.isEmpty { result.append(value) }
            for child in accessible.accessibilityChildren() ?? [] {
                collectLabels(child as AnyObject, visited: &visited, result: &result)
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            collectLabels(child, visited: &visited, result: &result)
        }
    }
}
