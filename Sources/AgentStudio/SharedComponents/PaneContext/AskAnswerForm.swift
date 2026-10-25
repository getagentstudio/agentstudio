import AgentStudioInfrastructure
import SwiftUI

package struct AskAnswerForm: View {
    private let form: AskFormModel
    private let submitControl: PaneContextControlModel
    private let scope: String?
    private let onSubmit: @MainActor (AskFormDraft) -> Void
    @State private var draft = AskFormDraft()
    package init(
        form: AskFormModel, submitControl: PaneContextControlModel, scope: String? = nil,
        onSubmit: @escaping @MainActor (AskFormDraft) -> Void
    ) {
        self.form = form
        self.scope = scope
        self.submitControl = submitControl
        self.onSubmit = onSubmit
    }
    package var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            switch form {
            case .choice(let options, let allowsMultiple):
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    if !allowsMultiple {
                        PaneContextActionButton(option.control, scope: scope) {
                            var answer = AskFormDraft()
                            answer.setChoice(option.id, selected: true, allowsMultiple: false)
                            onSubmit(answer)
                        }
                    } else {
                        Toggle(
                            option.label,
                            isOn: Binding(
                                get: { draft.selectedChoices.contains(option.id) },
                                set: { draft.setChoice(option.id, selected: $0, allowsMultiple: allowsMultiple) })
                        )
                        .toggleStyle(.checkbox)
                        .accessibilityHidden(true)
                        .background {
                            AccessibilityPressBridge(
                                identifier: option.control.identifier(in: scope), label: option.control.label,
                                value: draft.selectedChoices.contains(option.id) ? "Selected" : "Not selected",
                                help: option.control.tooltip.text,
                                action: {
                                    draft.setChoice(
                                        option.id, selected: !draft.selectedChoices.contains(option.id),
                                        allowsMultiple: allowsMultiple)
                                })
                        }
                    }
                }
            case .freeText(let placeholder):
                TextField(placeholder ?? "Reply", text: $draft.text, axis: .vertical)
                    .accessibilityLabel(placeholder ?? "Reply")
                    .accessibilityIdentifier(fieldIdentifier("text"))
            case .elicitation(let properties):
                ForEach(properties.indices, id: \.self) { index in
                    propertyControl(properties[index])
                }
            }
            if requiresSubmit { PaneContextActionButton(submitControl, scope: scope) { onSubmit(draft) } }
        }
    }

    private var requiresSubmit: Bool {
        switch form {
        case .choice(_, let allowsMultiple): allowsMultiple
        case .freeText, .elicitation: true
        }
    }

    @ViewBuilder
    private func propertyControl(_ property: ElicitationPropertyModel) -> some View {
        let title = property.title ?? property.name
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            switch property.kind {
            case .boolean:
                Toggle(
                    title,
                    isOn: Binding(
                        get: { draft.booleans[property.name] ?? false },
                        set: { draft.booleans[property.name] = $0 })
                )
                .toggleStyle(.checkbox)
                .accessibilityHidden(true)
                .background {
                    AccessibilityPressBridge(
                        identifier: fieldIdentifier(property.name), label: title,
                        value: String(draft.booleans[property.name] ?? false), help: property.description,
                        action: { draft.booleans[property.name] = !(draft.booleans[property.name] ?? false) })
                }
            case .string(let choices?, _, _, _):
                Picker(title, selection: fieldBinding(property.name)) {
                    Text("Choose…").tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier(fieldIdentifier(property.name))
            case .string, .number, .integer:
                TextField(title, text: fieldBinding(property.name))
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(fieldIdentifier(property.name))
            }
            if property.required { Text("Required").font(.caption).foregroundStyle(.secondary) }
            if let description = property.description { Text(description).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func fieldBinding(_ name: String) -> Binding<String> {
        Binding(get: { draft.fields[name] ?? "" }, set: { draft.fields[name] = $0 })
    }

    private func fieldIdentifier(_ name: String) -> String {
        "pane-context.field.\(scope.map { $0 + "." } ?? "")\(name)"
    }
}
