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
            case .freeText(let placeholder):
                TextField(placeholder ?? "Reply", text: $draft.text, axis: .vertical)
                    .accessibilityLabel(placeholder ?? "Reply")
            case .elicitation(let properties):
                ForEach(properties.indices, id: \.self) { index in
                    propertyControl(properties[index])
                }
            }
            PaneContextActionButton(submitControl, scope: scope) { onSubmit(draft) }
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
                .accessibilityLabel(title)
                .accessibilityIdentifier("pane-context.field.\(property.name)")
            case .string(let choices?, _, _, _):
                Picker(title, selection: fieldBinding(property.name)) {
                    Text("Choose…").tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityLabel(title)
            case .string, .number, .integer:
                TextField(title, text: fieldBinding(property.name))
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("pane-context.field.\(property.name)")
            }
            if property.required { Text("Required").font(.caption).foregroundStyle(.secondary) }
            if let description = property.description { Text(description).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func fieldBinding(_ name: String) -> Binding<String> {
        Binding(get: { draft.fields[name] ?? "" }, set: { draft.fields[name] = $0 })
    }
}
