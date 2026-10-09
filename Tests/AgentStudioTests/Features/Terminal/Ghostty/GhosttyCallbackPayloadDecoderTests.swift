import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@Suite("Ghostty callback payload decoder")
struct GhosttyCallbackPayloadDecoderTests {
    @Test("empty routed actions preserve payload variants and native handled results")
    func emptyRoutedActionsPreservePayloadVariantsAndHandledResults() {
        for expectation in Self.emptyUnionExpectations {
            let result = GhosttyCallbackPayloadDecoder.decode(emptyAction(for: expectation.actionTag))
            expect(result, toMatch: expectation.result)
        }

        let speciallyConstructedTags: Set<GhosttyActionTag> = [
            .setTitle,
            .setTabTitle,
            .pwd,
            .desktopNotification,
            .openURL,
            .commandFinished,
        ]
        let coveredTags = Set(Self.emptyUnionExpectations.map(\.actionTag))
            .union(speciallyConstructedTags)
        #expect(coveredTags == Ghostty.ActionRouter.explicitlyRoutedTags)
    }

    @Test("title and working-directory payloads copy strings before callback storage changes")
    func titleAndWorkingDirectoryPayloadsCopyBorrowedStrings() {
        var borrowedTitle = Array("copied-title".utf8CString)
        let titleResult = borrowedTitle.withUnsafeMutableBufferPointer { titleBuffer in
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_SET_TITLE,
                action: ghostty_action_u(
                    set_title: ghostty_action_set_title_s(title: titleBuffer.baseAddress)
                )
            )
            let result = GhosttyCallbackPayloadDecoder.decode(action)
            titleBuffer[0] = 88
            return result
        }
        expectPayload(titleResult, .titleChanged("copied-title"), handled: true)
        #expect(
            GhosttyActionTranslation.translate(actionTag: .setTitle, payload: .titleChanged("copied-title"))
                == .titleChanged("copied-title")
        )
        expectRejected(GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .setTitle)))

        var borrowedTabTitle = Array("copied-tab-title".utf8CString)
        let tabTitleResult = borrowedTabTitle.withUnsafeMutableBufferPointer { titleBuffer in
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_SET_TAB_TITLE,
                action: ghostty_action_u(
                    set_tab_title: ghostty_action_set_title_s(title: titleBuffer.baseAddress)
                )
            )
            let result = GhosttyCallbackPayloadDecoder.decode(action)
            titleBuffer[0] = 88
            return result
        }
        expectPayload(tabTitleResult, .tabTitleChanged("copied-tab-title"), handled: false)
        expectRejected(GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .setTabTitle)))

        var borrowedWorkingDirectory = Array("/tmp/copied-directory".utf8CString)
        let workingDirectoryResult = borrowedWorkingDirectory.withUnsafeMutableBufferPointer { directoryBuffer in
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_PWD,
                action: ghostty_action_u(pwd: ghostty_action_pwd_s(pwd: directoryBuffer.baseAddress))
            )
            let result = GhosttyCallbackPayloadDecoder.decode(action)
            directoryBuffer[0] = 88
            return result
        }
        expectPayload(
            workingDirectoryResult,
            .cwdChanged("/tmp/copied-directory"),
            handled: true
        )
        #expect(
            GhosttyActionTranslation.translate(
                actionTag: .pwd,
                payload: .cwdChanged("/tmp/copied-directory")
            ) == .cwdChanged("/tmp/copied-directory")
        )

        let nilWorkingDirectory = GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .pwd))
        expectDirectHost(nilWorkingDirectory, .workingDirectory(nil), handled: false)
    }

    @Test("reported size payloads preserve scalar values and false handled results")
    func reportedSizePayloadsPreserveValuesAndHandledResults() {
        let sizeLimitAction = ghostty_action_s(
            tag: GHOSTTY_ACTION_SIZE_LIMIT,
            action: ghostty_action_u(
                size_limit: ghostty_action_size_limit_s(
                    min_width: 80,
                    min_height: 24,
                    max_width: 160,
                    max_height: 48
                )
            )
        )
        expectPayload(
            GhosttyCallbackPayloadDecoder.decode(sizeLimitAction),
            .sizeLimitChanged(minWidth: 80, minHeight: 24, maxWidth: 160, maxHeight: 48),
            handled: false
        )

        let initialSizeAction = ghostty_action_s(
            tag: GHOSTTY_ACTION_INITIAL_SIZE,
            action: ghostty_action_u(initial_size: ghostty_action_initial_size_s(width: 1320, height: 780))
        )
        expectPayload(
            GhosttyCallbackPayloadDecoder.decode(initialSizeAction),
            .initialSizeChanged(width: 1320, height: 780),
            handled: false
        )

        let cellSizeAction = ghostty_action_s(
            tag: GHOSTTY_ACTION_CELL_SIZE,
            action: ghostty_action_u(cell_size: ghostty_action_cell_size_s(width: 9, height: 18))
        )
        expectPayload(
            GhosttyCallbackPayloadDecoder.decode(cellSizeAction),
            .cellSizeChanged(width: 9, height: 18),
            handled: false
        )
    }

    @Test("valid desktop notifications require and copy both message strings")
    func desktopNotificationsRequireAndCopyBothStrings() {
        var borrowedTitle = Array("notification-title".utf8CString)
        var borrowedBody = Array("notification-body".utf8CString)
        let validResult = borrowedTitle.withUnsafeMutableBufferPointer { titleBuffer in
            borrowedBody.withUnsafeMutableBufferPointer { bodyBuffer in
                let action = ghostty_action_s(
                    tag: GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
                    action: ghostty_action_u(
                        desktop_notification: ghostty_action_desktop_notification_s(
                            title: titleBuffer.baseAddress,
                            body: bodyBuffer.baseAddress
                        )
                    )
                )
                let result = GhosttyCallbackPayloadDecoder.decode(action)
                titleBuffer[0] = 88
                bodyBuffer[0] = 88
                return result
            }
        }
        expectPayload(
            validResult,
            .desktopNotification(title: "notification-title", body: "notification-body"),
            handled: false
        )
        expectRejected(GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .desktopNotification)))
    }

    @Test("valid openURL decodes copied bytes and malformed or absent URLs reject")
    func openURLCopiesBytesAndRejectsMalformedOrMissingValues() {
        var borrowedURL = Array("https://example.test/terminal".utf8CString)
        let validResult = borrowedURL.withUnsafeMutableBufferPointer { urlBuffer in
            let action = openURLAction(
                url: urlBuffer.baseAddress,
                byteCount: urlBuffer.count - 1,
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8
            )
            let result = GhosttyCallbackPayloadDecoder.decode(action)
            urlBuffer[0] = 88
            return result
        }
        expectPayload(
            validResult,
            .openURL(
                url: "https://example.test/terminal",
                kindRawValue: UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8.rawValue)
            ),
            handled: true
        )

        let malformedURL: [CChar] = [CChar(bitPattern: 0xff)]
        let malformedResult = malformedURL.withUnsafeBufferPointer { urlBuffer in
            GhosttyCallbackPayloadDecoder.decode(
                openURLAction(
                    url: urlBuffer.baseAddress,
                    byteCount: urlBuffer.count,
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8
                )
            )
        }
        expectRejected(malformedResult)
        expectRejected(GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .openURL)))
    }

    @Test("mouse-over-link retains nil and valid URL classifications and rejects malformed UTF-8")
    func mouseOverLinkPreservesOptionalURLClassification() {
        expectPayload(
            GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .mouseOverLink)),
            .mouseOverLink(nil),
            handled: false
        )

        var borrowedURL = Array("https://example.test/link".utf8CString)
        let validResult = borrowedURL.withUnsafeMutableBufferPointer { urlBuffer in
            let action = mouseOverLinkAction(url: urlBuffer.baseAddress, byteCount: urlBuffer.count - 1)
            let result = GhosttyCallbackPayloadDecoder.decode(action)
            urlBuffer[0] = 88
            return result
        }
        expectPayload(validResult, .mouseOverLink("https://example.test/link"), handled: false)

        let malformedURL: [CChar] = [CChar(bitPattern: 0xff)]
        let malformedResult = malformedURL.withUnsafeBufferPointer { urlBuffer in
            GhosttyCallbackPayloadDecoder.decode(
                mouseOverLinkAction(url: urlBuffer.baseAddress, byteCount: urlBuffer.count)
            )
        }
        expectRejected(malformedResult)
    }

    @Test("commandFinished captures its source instant during decode and keeps it on the payload")
    func commandFinishedRetainsDecodeSourceInstantThroughTranslation() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_COMMAND_FINISHED,
            action: ghostty_action_u(
                command_finished: ghostty_action_command_finished_s(exit_code: 7, duration: 42)
            )
        )
        let result = GhosttyCallbackPayloadDecoder.decode(action)

        guard case .payload(let payload, let handled) = result,
            case .commandFinished(let exitCode, let duration, let sourceInstant) = payload
        else {
            Issue.record("Expected a decoded commandFinished payload")
            return
        }
        #expect(handled)
        #expect(exitCode == 7)
        #expect(duration == 42)
        let copiedPayload = payload
        #expect(
            copiedPayload
                == .commandFinished(
                    exitCode: exitCode,
                    duration: duration,
                    sourceInstant: sourceInstant
                )
        )
        #expect(
            GhosttyActionTranslation.translate(actionTag: .commandFinished, payload: copiedPayload)
                == .commandFinished(exitCode: 7, duration: 42)
        )
    }

    @Test("existing intercepted and unsupported tables remain distinct from unknown tags")
    func interceptedUnsupportedAndUnknownTagsKeepTheirDisposition() {
        let intercepted = GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .quit))
        expectIntercepted(intercepted, tag: .quit)

        expectRejected(GhosttyCallbackPayloadDecoder.decode(emptyAction(for: .exportTerminalIO)))

        let unknownAction = ghostty_action_s(
            tag: ghostty_action_tag_e(rawValue: UInt32.max),
            action: ghostty_action_u()
        )
        expectRejected(GhosttyCallbackPayloadDecoder.decode(unknownAction))
    }

    private static let emptyUnionExpectations: [ExpectedEmptyUnionDecode] = [
        .init(actionTag: .newTab, result: .payload(.noPayload, handled: true)),
        .init(actionTag: .ringBell, result: .payload(.noPayload, handled: true)),
        .init(actionTag: .newSplit, result: .payload(.newSplit(directionRawValue: 0), handled: true)),
        .init(actionTag: .gotoSplit, result: .payload(.gotoSplit(directionRawValue: 0), handled: true)),
        .init(actionTag: .resizeSplit, result: .payload(.resizeSplit(amount: 0, directionRawValue: 0), handled: true)),
        .init(actionTag: .equalizeSplits, result: .payload(.noPayload, handled: true)),
        .init(actionTag: .toggleSplitZoom, result: .payload(.noPayload, handled: true)),
        .init(actionTag: .closeTab, result: .payload(.closeTab(modeRawValue: 0), handled: true)),
        .init(actionTag: .gotoTab, result: .payload(.gotoTab(targetRawValue: 0), handled: true)),
        .init(actionTag: .moveTab, result: .payload(.moveTab(amount: 0), handled: true)),
        .init(
            actionTag: .sizeLimit,
            result: .payload(.sizeLimitChanged(minWidth: 0, minHeight: 0, maxWidth: 0, maxHeight: 0), handled: false)
        ),
        .init(actionTag: .initialSize, result: .payload(.initialSizeChanged(width: 0, height: 0), handled: false)),
        .init(actionTag: .cellSize, result: .payload(.cellSizeChanged(width: 0, height: 0), handled: false)),
        .init(actionTag: .promptTitle, result: .payload(.promptTitle(scopeRawValue: 0), handled: false)),
        .init(actionTag: .mouseShape, result: .payload(.mouseShape(rawValue: 0), handled: false)),
        .init(actionTag: .mouseVisibility, result: .payload(.mouseVisibility(rawValue: 0), handled: false)),
        .init(actionTag: .mouseOverLink, result: .payload(.mouseOverLink(nil), handled: false)),
        .init(actionTag: .rendererHealth, result: .payload(.rendererHealth(rawValue: 0), handled: false)),
        .init(actionTag: .secureInput, result: .payload(.secureInput(modeRawValue: 0), handled: false)),
        .init(
            actionTag: .keySequence,
            result: .payload(.keySequence(active: false, triggerTag: 0, key: 0, mods: 0), handled: false)
        ),
        .init(actionTag: .keyTable, result: .payload(.keyTable(tagRawValue: 0, activateName: nil), handled: false)),
        .init(
            actionTag: .colorChange,
            result: .payload(.colorChange(kindRawValue: 0, red: 0, green: 0, blue: 0), handled: false)
        ),
        .init(actionTag: .reloadConfig, result: .payload(.reloadConfig(soft: false), handled: false)),
        .init(actionTag: .configChange, result: .payload(.configChange, handled: false)),
        .init(actionTag: .undo, result: .payload(.noPayload, handled: false)),
        .init(actionTag: .redo, result: .payload(.noPayload, handled: false)),
        .init(
            actionTag: .progressReport, result: .payload(.progressReport(stateRawValue: 0, progress: 0), handled: false)
        ),
        .init(actionTag: .scrollbar, result: .payload(.scrollbar(total: 0, offset: 0, length: 0), handled: false)),
        .init(actionTag: .startSearch, result: .payload(.startSearch(nil), handled: false)),
        .init(actionTag: .endSearch, result: .payload(.endSearch, handled: false)),
        .init(actionTag: .searchTotal, result: .payload(.searchTotal(0), handled: false)),
        .init(actionTag: .searchSelected, result: .payload(.searchSelected(0), handled: false)),
        .init(actionTag: .readOnly, result: .payload(.readOnly(modeRawValue: 0), handled: false)),
        .init(actionTag: .copyTitleToClipboard, result: .payload(.noPayload, handled: false)),
    ]

    private static let speciallyConstructedTags: Set<GhosttyActionTag> = [
        .setTitle,
        .setTabTitle,
        .pwd,
        .desktopNotification,
        .openURL,
        .commandFinished,
    ]
}

private struct ExpectedEmptyUnionDecode {
    let actionTag: GhosttyActionTag
    let result: ExpectedPayloadDecodeResult
}

private enum ExpectedPayloadDecodeResult {
    case payload(GhosttyActionPayload, handled: Bool)
    case directHost(GhosttyDirectHostUpdate, handled: Bool)
    case rejected
}

private func emptyAction(for tag: GhosttyActionTag) -> ghostty_action_s {
    ghostty_action_s(
        tag: ghostty_action_tag_e(rawValue: tag.rawValue),
        action: ghostty_action_u()
    )
}

private func openURLAction(
    url: UnsafePointer<CChar>?,
    byteCount: Int,
    kind: ghostty_action_open_url_kind_e
) -> ghostty_action_s {
    ghostty_action_s(
        tag: GHOSTTY_ACTION_OPEN_URL,
        action: ghostty_action_u(
            open_url: ghostty_action_open_url_s(
                kind: kind,
                url: url,
                len: UInt(byteCount)
            )
        )
    )
}

private func mouseOverLinkAction(url: UnsafePointer<CChar>?, byteCount: Int) -> ghostty_action_s {
    ghostty_action_s(
        tag: GHOSTTY_ACTION_MOUSE_OVER_LINK,
        action: ghostty_action_u(
            mouse_over_link: ghostty_action_mouse_over_link_s(
                url: url,
                len: byteCount
            )
        )
    )
}

private func expect(_ actual: GhosttyCallbackPayloadDecodeResult, toMatch expected: ExpectedPayloadDecodeResult) {
    switch (actual, expected) {
    case (
        .payload(let actualPayload, handled: let actualHandled),
        .payload(let expectedPayload, handled: let expectedHandled)
    ):
        #expect(actualPayload == expectedPayload)
        #expect(actualHandled == expectedHandled)
    case (
        .directHost(let actualUpdate, handled: let actualHandled),
        .directHost(let expectedUpdate, handled: let expectedHandled)
    ):
        #expect(actualUpdate == expectedUpdate)
        #expect(actualHandled == expectedHandled)
    case (.rejected, .rejected):
        break
    default:
        Issue.record("Decoded callback result did not match the expected variant")
    }
}

private func expectPayload(
    _ actual: GhosttyCallbackPayloadDecodeResult,
    _ expectedPayload: GhosttyActionPayload,
    handled: Bool
) {
    expect(actual, toMatch: .payload(expectedPayload, handled: handled))
}

private func expectDirectHost(
    _ actual: GhosttyCallbackPayloadDecodeResult,
    _ expectedUpdate: GhosttyDirectHostUpdate,
    handled: Bool
) {
    expect(actual, toMatch: .directHost(expectedUpdate, handled: handled))
}

private func expectRejected(_ actual: GhosttyCallbackPayloadDecodeResult) {
    expect(actual, toMatch: .rejected)
}

private func expectIntercepted(_ actual: GhosttyCallbackPayloadDecodeResult, tag expectedTag: GhosttyActionTag) {
    guard case .intercepted(let actualTag) = actual else {
        Issue.record("Expected an intercepted callback tag")
        return
    }
    #expect(actualTag.rawValue == expectedTag.rawValue)
}
