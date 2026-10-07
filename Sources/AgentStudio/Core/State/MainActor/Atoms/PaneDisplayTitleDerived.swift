@MainActor
package struct PaneDisplayTitleDerived {
    private let presentation: PaneContextPresentationAtom

    package init(presentation: PaneContextPresentationAtom) {
        self.presentation = presentation
    }

    package func title(for paneId: PaneId, fallbackTitle: String) -> String {
        presentation.value(for: paneId)?.agentTitle ?? fallbackTitle
    }
}
