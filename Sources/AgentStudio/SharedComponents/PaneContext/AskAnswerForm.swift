import AgentStudioInfrastructure
import SwiftUI

package struct AskAnswerForm: View {
    package enum Layout: Sendable, CaseIterable, Hashable { case messages, card }
    private let layout: Layout
    private let form: AskFormModel
    private let submitControl: PaneContextControlModel
    private let scope: String?
    private let onSubmit: @MainActor (AskFormDraft) -> Void
    @State private var draft = AskFormDraft()
    package init(
        form: AskFormModel, submitControl: PaneContextControlModel, scope: String? = nil, layout: Layout = .card,
        onSubmit: @escaping @MainActor (AskFormDraft) -> Void
    ) {
        self.form = form
        self.layout = layout
        self.scope = scope
        self.submitControl = submitControl
        self.onSubmit = onSubmit
    }
    package var body: some View {
        switch layout {
        case .messages: formContent.font(.system(size: AppStyles.General.Typography.textSm))
        case .card: formContent
        }
    }

    private var formContent: some View {
        VStack(
            alignment: .leading,
            spacing: layout == .messages ? AppStyles.General.Spacing.loose : AppStyles.General.Spacing.standard
        ) {
            switch form {
            case .approval(let approve, let deny, let reason):
                approvalReason(reason)
                HStack(
                    spacing: layout == .messages ? AppStyles.General.Spacing.loose : AppStyles.General.Spacing.standard
                ) {
                    PaneContextActionButton(approve, role: .commit, scope: scope) { submitDecision(.approve) }
                    PaneContextActionButton(deny, role: .alternative, scope: scope) { submitDecision(.deny) }
                }
            case .choice(let options, let allowsMultiple):
                choices(options, allowsMultiple: allowsMultiple)
            case .freeText(let placeholder):
                TextField(placeholder ?? "Reply", text: $draft.text, axis: .vertical)
                    .accessibilityLabel(placeholder ?? "Reply")
                    .accessibilityIdentifier(fieldIdentifier("text"))
            case .elicitation(let properties):
                ForEach(properties.indices, id: \.self) { index in propertyControl(properties[index]) }
            }
            if requiresSubmit {
                PaneContextActionButton(submitControl, role: .commit, scope: scope) { onSubmit(draft) }
            }
        }
    }

    @ViewBuilder private func approvalReason(_ reason: PaneContextControlModel) -> some View {
        switch layout {
        case .card:
            TextField(reason.label, text: $draft.text)
                .accessibilityLabel(reason.label)
                .accessibilityIdentifier(fieldIdentifier("reason"))
                .controlHelp(reason.tooltip)
        case .messages:
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
                Text(reason.label)
                    .background {
                        AccessibilityLabelBridge(
                            identifier: fieldIdentifier("reason-label"), label: reason.label, role: .staticText)
                    }
                    .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $draft.text, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, AppStyles.General.Spacing.loose)
                    .padding(.vertical, AppStyles.General.Spacing.standard)
                    .frame(minHeight: AppStyles.Components.PaneContext.reasonFieldMinimumHeight, alignment: .top)
                    .background {
                        RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                            .fill(Color.white.opacity(AppStyles.General.Fill.subtle))
                            .overlay {
                                RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                                    .stroke(Color.white.opacity(AppStyles.General.Stroke.muted))
                            }
                    }
                    .accessibilityLabel(reason.label)
                    .accessibilityIdentifier(fieldIdentifier("reason"))
                    .controlHelp(reason.tooltip)
            }
        }
    }

    @ViewBuilder private func choices(_ options: [AskChoiceModel], allowsMultiple: Bool) -> some View {
        if allowsMultiple {
            ForEach(options.indices, id: \.self) { index in checkbox(options[index]) }
        } else if layout == .messages {
            PaneContextFlowLayout {
                ForEach(options.indices, id: \.self) { index in singleChoice(options[index]) }
            }
        } else {
            ForEach(options.indices, id: \.self) { index in singleChoice(options[index]) }
        }
    }

    private func singleChoice(_ option: AskChoiceModel) -> some View {
        PaneContextActionButton(option.control, role: .alternative, scope: scope) {
            var answer = AskFormDraft()
            answer.setChoice(option.id, selected: true, allowsMultiple: false)
            onSubmit(answer)
        }
    }

    private func checkbox(_ option: AskChoiceModel) -> some View {
        Toggle(
            isOn: Binding(
                get: { draft.selectedChoices.contains(option.id) },
                set: { draft.setChoice(option.id, selected: $0, allowsMultiple: true) })
        ) {
            Text(option.label).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: option.control.identifier(in: scope), label: option.control.label,
                value: draft.selectedChoices.contains(option.id) ? "Selected" : "Not selected",
                help: option.control.tooltip.text,
                action: {
                    draft.setChoice(
                        option.id, selected: !draft.selectedChoices.contains(option.id), allowsMultiple: true)
                })
        }
    }

    private var requiresSubmit: Bool {
        switch form {
        case .approval: false
        case .choice(_, let allowsMultiple): allowsMultiple
        case .freeText, .elicitation: true
        }
    }

    private func submitDecision(_ decision: ApprovalDecisionModel) {
        var answer = draft
        answer.approvalDecision = decision
        onSubmit(answer)
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
