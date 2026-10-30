import AgentStudioInfrastructure
import SwiftUI

package struct AskAnswerForm: View {
    package struct DetailsAction {
        let control: PaneContextControlModel
        let scope: String
        let octiconLoader: OcticonLoader
        let isSelected: Bool
        let perform: @MainActor () -> Void
    }

    package enum Layout: Sendable, CaseIterable, Hashable { case messages, card }
    private let layout: Layout
    private let form: AskFormModel
    private let submitControl: PaneContextControlModel
    private let scope: String?
    private let choicePrompt: PaneContextControlModel?
    private let requiredField: PaneContextControlModel?
    private let details: DetailsAction?
    private let onSubmit: @MainActor (AskFormDraft) -> Void
    @Binding private var draft: AskFormDraft
    package init(
        form: AskFormModel, draft: Binding<AskFormDraft>, submitControl: PaneContextControlModel,
        scope: String? = nil, layout: Layout = .card,
        choicePrompt: PaneContextControlModel? = nil, requiredField: PaneContextControlModel? = nil,
        details: DetailsAction? = nil,
        onSubmit: @escaping @MainActor (AskFormDraft) -> Void
    ) {
        self.details = details
        self.choicePrompt = choicePrompt
        self.requiredField = requiredField
        self.form = form
        self._draft = draft
        self.layout = layout
        self.scope = scope
        self.submitControl = submitControl
        self.onSubmit = onSubmit
    }
    package var body: some View {
        formContent
            .font(.system(size: AppStyles.General.Typography.textSm))
            .padding(AppStyles.Components.PopoverPanel.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppStyles.General.CornerRadius.panel)
                    .fill(AppStyles.General.ControlSurface.fill)
            }
    }

    private var formContent: some View {
        VStack(
            alignment: .leading,
            spacing: layout == .messages ? AppStyles.General.Spacing.loose : AppStyles.General.Spacing.standard
        ) {
            switch form {
            case .approval(_, _, let reason):
                approvalReason(reason)
            case .choice(let options, let presentation):
                choices(options, presentation: presentation)
            case .freeText(let placeholder):
                TextField(placeholder ?? "Reply", text: $draft.text, axis: .vertical)
                    .accessibilityLabel(placeholder ?? "Reply")
                    .accessibilityIdentifier(fieldIdentifier("text"))
            case .elicitation(let properties):
                ForEach(properties.indices, id: \.self) { index in propertyControl(properties[index]) }
            }
            commitRow
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
                            .fill(AppStyles.General.ControlSurface.fill)
                            .overlay {
                                RoundedRectangle(cornerRadius: AppStyles.Components.PaneContext.formControlCornerRadius)
                                    .strokeBorder(AppStyles.General.ControlSurface.separator)
                            }
                    }
                    .accessibilityLabel(reason.label)
                    .accessibilityIdentifier(fieldIdentifier("reason"))
                    .controlHelp(reason.tooltip)
            }
        }
    }

    @ViewBuilder private func choices(_ options: [AskChoiceModel], presentation: AskChoicePresentation) -> some View {
        if presentation == .checkboxes {
            ForEach(options.indices, id: \.self) { index in checkbox(options[index]) }
        } else {
            if presentation == .picker {
                Picker(choicePrompt?.label ?? "", selection: singleChoiceBinding) {
                    Text(choicePrompt?.label ?? "").tag(String?.none)
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].label).tag(String?.some(options[index].id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(choicePrompt?.label ?? "")
                .accessibilityIdentifier(fieldIdentifier("choice"))
            } else {
                Picker(choicePrompt?.label ?? "", selection: singleChoiceBinding) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].label)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(String?.some(options[index].id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier(fieldIdentifier("choice"))
            }
        }
    }

    private var singleChoiceBinding: Binding<String?> {
        Binding(
            get: { draft.selectedChoices.first },
            set: { selected in
                if let selected { draft.setChoice(selected, selected: true, allowsMultiple: false) }
            })
    }

    private var canSubmit: Bool {
        switch form {
        case .choice(_, .radio), .choice(_, .picker): !draft.selectedChoices.isEmpty
        case .elicitation(let properties):
            properties.allSatisfy { property in
                guard property.required else { return true }
                if case .boolean = property.kind { return true }
                return !(draft.fields[property.name] ?? "").isEmpty
            }
        // The existing multiple-choice contract admits an empty list; keep that schema.
        case .choice(_, .checkboxes), .approval, .freeText: true
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

    private var commitRow: some View {
        HStack(spacing: layout == .messages ? AppStyles.General.Spacing.loose : AppStyles.General.Spacing.standard) {
            if case .approval(let approve, let deny, _) = form {
                PaneContextActionButton(approve, role: .commit, scope: scope) { submitDecision(.approve) }
                PaneContextActionButton(deny, role: .alternative, scope: scope) { submitDecision(.deny) }
            } else {
                PaneContextActionButton(submitControl, role: .commit, scope: scope) { onSubmit(draft) }
                    .disabled(!canSubmit)
            }
            if let details {
                PaneContextActionButton(
                    details.control, role: .details(details.octiconLoader), scope: details.scope,
                    isSelected: details.isSelected, action: details.perform)
            }
        }
    }

    private func submitDecision(_ decision: ApprovalDecisionModel) {
        var answer = draft
        answer.approvalDecision = decision
        onSubmit(answer)
    }

    @ViewBuilder
    private func propertyControl(_ property: ElicitationPropertyModel) -> some View {
        let title = property.title
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            if case .boolean = property.kind {
                EmptyView()
            } else {
                HStack(spacing: AppStyles.General.Spacing.tight) {
                    Text(title).fontWeight(.medium)
                    if property.required, let requiredField {
                        Text("*").accessibilityLabel(requiredField.label).foregroundStyle(.secondary)
                    }
                }
            }
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
                    Text(choicePrompt?.label ?? "").tag("")
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(fieldIdentifier(property.name))
            case .string, .number, .integer:
                TextField(title, text: fieldBinding(property.name))
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(fieldIdentifier(property.name))
                    .onSubmit { onSubmit(draft) }
            }
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
