import AgentStudioBridge
import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInboxNotification
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioTerminal

@MainActor
final class AtomRegistry {
    let core: CoreAtoms
    let repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom
    let terminalActivity: TerminalActivityAtom
    let editorPreference: EditorPreferenceAtom
    let editorChooserRuntime: EditorChooserRuntimeAtom
    let editorChooser: EditorChooserState
    let inboxNotification: InboxNotificationAtom
    let inboxNotificationPrefs: InboxNotificationPrefsAtom
    let inboxSidebarMemory: InboxSidebarMemoryAtom
    let inboxSidebarRuntime: InboxSidebarRuntimeAtom
    let inboxSidebarState: InboxSidebarState
    let paneInboxPresentationState: PaneInboxPresentationAtom
    let bridgePaneAttendance: BridgePaneAttendanceAtom
    let sessionStatus: SessionStatusAtom
    let sessionsPaneViewedMailbox: SessionsPaneViewedMailbox
    var paneContextPresentation: PaneContextPresentationAtom { core.paneContextPresentation }

    init(
        core: CoreAtoms = .init(),
        repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom? = nil,
        terminalActivity: TerminalActivityAtom = .init(),
        editorPreference: EditorPreferenceAtom = .init(),
        editorChooserRuntime: EditorChooserRuntimeAtom = .init(),
        inboxNotification: InboxNotificationAtom = .init(),
        inboxNotificationPrefs: InboxNotificationPrefsAtom = .init(),
        inboxSidebarMemory: InboxSidebarMemoryAtom = .init(),
        inboxSidebarRuntime: InboxSidebarRuntimeAtom = .init(),
        paneInboxPresentationState: PaneInboxPresentationAtom = .init(),
        bridgePaneAttendance: BridgePaneAttendanceAtom = .init(),
        sessionStatus: SessionStatusAtom = .init(),
        sessionsPaneViewedMailbox: SessionsPaneViewedMailbox = .init()
    ) {
        self.core = core
        self.repoExplorerSidebarPrefs =
            repoExplorerSidebarPrefs
            ?? RepoExplorerSidebarPrefsAtom(sidebarState: core.workspaceSidebarState)
        self.terminalActivity = terminalActivity
        self.editorPreference = editorPreference
        self.editorChooserRuntime = editorChooserRuntime
        self.editorChooser = EditorChooserState(
            preferenceAtom: editorPreference,
            runtimeAtom: editorChooserRuntime
        )
        self.inboxNotification = inboxNotification
        self.inboxNotificationPrefs = inboxNotificationPrefs
        self.inboxSidebarMemory = inboxSidebarMemory
        self.inboxSidebarRuntime = inboxSidebarRuntime
        self.inboxSidebarState = InboxSidebarState(
            memoryAtom: inboxSidebarMemory,
            runtimeAtom: inboxSidebarRuntime
        )
        self.paneInboxPresentationState = paneInboxPresentationState
        self.bridgePaneAttendance = bridgePaneAttendance
        self.sessionStatus = sessionStatus
        self.sessionsPaneViewedMailbox = sessionsPaneViewedMailbox
    }
}
