import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Posts and withdraws the browser notice in a target pane. The drawer
/// browser pane is the notice's sender, and its Open action goes to that pane.
@MainActor
protocol DrawerBrowserNoticePosting: AnyObject {
    /// True when the notice was stored.
    func postNotice(messageId: UUID, in parentPaneId: UUID, browserPaneId: UUID, body: String) async -> Bool
    /// Withdraws an earlier notice. A refusal (already read, gone) is ignored.
    func withdrawNotice(messageId: UUID, in parentPaneId: UUID, browserPaneId: UUID) async
}

/// Browser notices through the pane context service.
@MainActor
final class PaneContextDrawerBrowserNotices: DrawerBrowserNoticePosting {
    private let service: @MainActor () -> PaneContextService?

    init(service: @escaping @MainActor () -> PaneContextService?) {
        self.service = service
    }

    func postNotice(messageId: UUID, in parentPaneId: UUID, browserPaneId: UUID, body: String) async -> Bool {
        guard let service = service() else { return false }
        let result = await service.send(
            PaneMessageSendRequest(
                paneId: PaneId(existingUUID: parentPaneId), messageId: AgentMessageId(existingUUID: messageId),
                sender: .pane(PaneId(existingUUID: browserPaneId)), sourceOccurredAt: nil, importance: .info,
                body: body, why: nil, actions: [.goToPane(PaneId(existingUUID: browserPaneId))], shape: .notice))
        switch result {
        case .created, .existing: return true
        case .refused, .unavailable: return false
        }
    }

    func withdrawNotice(messageId: UUID, in parentPaneId: UUID, browserPaneId: UUID) async {
        guard let service = service() else { return }
        _ = await service.withdraw(
            messageId: AgentMessageId(existingUUID: messageId), paneId: PaneId(existingUUID: parentPaneId),
            writer: .pane(PaneId(existingUUID: browserPaneId)))
    }
}

/// Runs `drawer.browse` opens one at a time per target pane, and keeps each
/// pane's last unread browser notice so the next open replaces it. A show joins
/// its pane's queue in the same turn it arrives, before any suspension; shows
/// for different panes run independently; a failed show releases the queue.
@MainActor
final class DrawerBrowserShows {
    struct Shown: Equatable {
        let opened: DrawerBrowserOpenResult
        let noticePosted: Bool
    }

    private struct PostedNotice {
        let messageId: UUID
        let browserPaneId: UUID
    }

    private let notices: any DrawerBrowserNoticePosting
    private var tails: [UUID: Task<Void, Never>] = [:]
    private var lastNotices: [UUID: PostedNotice] = [:]

    init(notices: any DrawerBrowserNoticePosting) {
        self.notices = notices
    }

    func show(
        parentPaneId: UUID,
        noticeBody: String,
        open: @escaping @MainActor () async throws -> DrawerBrowserOpenResult
    ) async throws -> Shown {
        let predecessor = tails[parentPaneId]
        let work = Task { @MainActor [self] () throws -> Shown in
            _ = await predecessor?.value
            let opened = try await open()
            if let last = lastNotices.removeValue(forKey: parentPaneId) {
                await notices.withdrawNotice(
                    messageId: last.messageId, in: parentPaneId, browserPaneId: last.browserPaneId)
            }
            let messageId = UUIDv7.generate()
            let posted = await notices.postNotice(
                messageId: messageId, in: parentPaneId, browserPaneId: opened.childPaneId, body: noticeBody)
            if posted {
                lastNotices[parentPaneId] = PostedNotice(messageId: messageId, browserPaneId: opened.childPaneId)
            }
            return Shown(opened: opened, noticePosted: posted)
        }
        tails[parentPaneId] = Task { _ = try? await work.value }
        return try await work.value
    }
}

/// Which pages `drawer.browse` admits: an http or https URL with a host, or
/// an existing regular `.html` or `.htm` file at an absolute path. A directory,
/// pipe, socket or device with that name is not a page.
enum DrawerBrowserPageAdmission {
    @concurrent nonisolated static func admit(_ page: IPCDrawerBrowserPage) async throws -> URL {
        switch page {
        case .web(let rawURL):
            guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https", url.host()?.isEmpty == false
            else { throw AppIPCLayoutError(reason: .unsupportedPage) }
            return url
        case .localHTML(let path):
            let pathExtension = (path as NSString).pathExtension.lowercased()
            guard path.hasPrefix("/"), pathExtension == "html" || pathExtension == "htm" else {
                throw AppIPCLayoutError(reason: .unsupportedPage)
            }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                throw AppIPCLayoutError(reason: .fileNotFound)
            }
            return url
        }
    }

    /// The notice text: the page's host, or its file name.
    nonisolated static func noticeBody(for url: URL) -> String {
        let name = url.isFileURL ? url.lastPathComponent : (url.host() ?? url.absoluteString)
        return "Opened \(name) in the drawer browser"
    }
}
