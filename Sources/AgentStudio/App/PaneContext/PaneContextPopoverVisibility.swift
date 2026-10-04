import AgentStudioCore

enum PaneContextPopoverVisibility {
    static func hostIsVisible(isActiveTab: Bool, windowFacts: WindowPresentationFacts?) -> Bool {
        guard isActiveTab else { return false }
        guard let windowFacts else { return true }
        return windowFacts.isVisible && !windowFacts.isMiniaturized && !windowFacts.isOccluded
    }
}
