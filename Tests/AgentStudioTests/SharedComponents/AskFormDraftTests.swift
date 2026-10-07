import Testing

@testable import AgentStudioSharedComponents

struct AskFormDraftTests {
    @Test
    func singleChoiceReplacesSelectionAndMultiChoiceKeepsBoth() {
        var single = AskFormDraft()
        single.setChoice("allow", selected: true, allowsMultiple: false)
        single.setChoice("deny", selected: true, allowsMultiple: false)
        #expect(single.selectedChoices == ["deny"])
        var multiple = AskFormDraft()
        multiple.setChoice("allow", selected: true, allowsMultiple: true)
        multiple.setChoice("deny", selected: true, allowsMultiple: true)
        multiple.setChoice("allow", selected: true, allowsMultiple: true)
        #expect(multiple.selectedChoices == ["allow", "deny"])
        multiple.setChoice("allow", selected: false, allowsMultiple: true)
        #expect(multiple.selectedChoices == ["deny"])
    }

    @Test
    func rawInputStaysLocalUntilTheAppBuildsTheAnswer() {
        var draft = AskFormDraft()
        draft.text = "Reply"
        draft.fields["number"] = "invalid number"
        draft.booleans["enabled"] = false
        #expect(draft.text == "Reply")
        #expect(draft.fields["number"] == "invalid number")
        #expect(draft.booleans["enabled"] == false)
        #expect(draft.booleanAnswers == ["enabled": .boolean(false)])
        draft.booleans["enabled"] = true
        #expect(draft.booleanAnswers == ["enabled": .boolean(true)])
    }
}
