import Foundation

package enum ProviderIntegrationInspector {
    package struct Props {
        package let layout: ProviderIntegrationLayout
        package let environment: [String: String]
        package var codexVersion: (() -> String?)?
    }

    package static func inspect(_ props: Props) -> ProviderIntegrationStatus {
        let layout = props.layout
        var problems: [ProviderIntegrationProblem] = []
        let notes: [ProviderIntegrationNote] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: layout.home.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return .init(provider: layout.provider, problems: [.homeMissing(path: layout.home.path)], notes: []) }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: layout.home.path) } catch {
            return .init(
                provider: layout.provider,
                problems: [.homeUnreadable(path: layout.home.path, reason: error.localizedDescription)], notes: [])
        }
        let document: ProviderHookFileDocument?
        do {
            let data: Data?
            do { data = try ProviderIntegrationInstaller.readIfPresent(layout.hookFileURL) } catch {
                problems.append(.hookFileUnreadable(path: layout.hookFileURL.path, reason: error.localizedDescription))
                return inspectScriptAndFinish(props, problems: problems, notes: notes, document: nil)
            }
            document = try ProviderHookFileDocument(
                provider: layout.provider, data: data, path: layout.hookFileURL.path)
        } catch {
            problems.append(.hookFileUnparseable(path: layout.hookFileURL.path, reason: error.localizedDescription))
            document = nil
        }
        if let document { inspectEntries(document, layout: layout, problems: &problems) }
        return inspectScriptAndFinish(props, problems: problems, notes: notes, document: document)
    }

    private static func inspectScriptAndFinish(
        _ props: Props, problems initial: [ProviderIntegrationProblem], notes initialNotes: [ProviderIntegrationNote],
        document: ProviderHookFileDocument?
    ) -> ProviderIntegrationStatus {
        let layout = props.layout
        var problems = initial
        var notes = initialNotes
        let owned =
            document?.groupsByEvent.values.flatMap { $0 }.flatMap(\.handlers)
            .contains { ProviderHookOwnership.classify($0, layout: layout) != .foreign } ?? false
        if FileManager.default.fileExists(atPath: layout.scriptURL.path) {
            if !FileManager.default.isReadableFile(atPath: layout.scriptURL.path)
                || FileManager.default.contents(atPath: layout.scriptURL.path) == nil
            {
                problems.append(
                    .scriptUnreadable(path: layout.scriptURL.path, reason: "cannot read installed hook script"))
            }
            let expected = ProviderIntegrationVersion.current(for: layout.provider)
            if let data = FileManager.default.contents(atPath: layout.versionURL.path),
                let text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, text.allSatisfy(\.isNumber), let installed = Int(text)
            {
                if installed < expected {
                    problems.append(
                        .scriptOutdated(path: layout.scriptURL.path, installed: installed, expected: expected))
                }
                if installed > expected {
                    notes.append(.installedByNewerAgentStudio(installed: installed, expected: expected))
                }
            } else {
                problems.append(
                    .versionUnreadable(
                        path: layout.versionURL.path, reason: "expected a readable decimal integration version"))
            }
        } else if owned {
            problems.append(.scriptMissing(path: layout.scriptURL.path))
        } else if document != nil {
            problems.append(.notInstalled(path: layout.home.path))
        }
        if layout.provider == .codex { inspectCodex(props, document: document, problems: &problems) }
        return .init(provider: layout.provider, problems: problems, notes: notes)
    }

    private static func inspectEntries(
        _ document: ProviderHookFileDocument, layout: ProviderIntegrationLayout,
        problems: inout [ProviderIntegrationProblem]
    ) {
        let expectedEntries = ProviderExpectedEntries.entries(layout: layout)
        let eventOrder = document.eventOrder + expectedEntries.map(\.event).filter { !document.eventOrder.contains($0) }
        for event in eventOrder {
            for group in document.groupsByEvent[event] ?? [] {
                for handler in group.handlers where ProviderHookOwnership.classify(handler, layout: layout) == .legacy {
                    problems.append(.legacyEntry(event: event, path: layout.hookFileURL.path))
                }
            }
            guard let expected = expectedEntries.first(where: { $0.event == event }) else { continue }
            let owned = (document.groupsByEvent[expected.event] ?? []).flatMap { group in
                group.handlers.compactMap { handler -> (ProviderHookGroup, ProviderCommandHook)? in
                    guard ProviderHookOwnership.classify(handler, layout: layout) != .foreign,
                        case .command(let command) = handler
                    else { return nil }
                    return (group, command)
                }
            }
            guard let first = owned.first, case .command(let desired)? = expected.group.handlers.first else {
                problems.append(.entryMissing(event: expected.event, path: layout.hookFileURL.path))
                continue
            }
            var aspects: [ProviderHookEntryAspect] = []
            if first.0.matcher != expected.group.matcher { aspects.append(.matcher) }
            if owned.count != 1 || first.1.command != desired.command { aspects.append(.command) }
            if first.1.timeoutSeconds != desired.timeoutSeconds { aspects.append(.timeout) }
            if first.1.isAsync != desired.isAsync { aspects.append(.asynchronous) }
            for aspect in aspects {
                problems.append(.entryModified(event: expected.event, path: layout.hookFileURL.path, aspect: aspect))
            }
        }
    }

    private struct OwnedCodexHook {
        let event: String
        let groupIndex: Int
        let handlerIndex: Int
        let group: ProviderHookGroup
        let handler: ProviderCommandHook
    }

    private static func inspectCodex(
        _ props: Props, document: ProviderHookFileDocument?, problems: inout [ProviderIntegrationProblem]
    ) {
        let layout = props.layout
        let config = layout.home.appending(path: "config.toml")
        let review: CodexHookReviewDocument
        do {
            let data = try ProviderIntegrationInstaller.readIfPresent(config) ?? Data()
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            review = try CodexHookReviewStateReader.read(text)
            if !review.hooksEnabled { problems.append(.codexHooksFeatureOff(path: config.path)) }
        } catch {
            problems.append(.codexTrustUnknown(reason: .stateUnreadable(path: config.path)))
            return
        }
        guard let document else { return }
        let owned = document.eventOrder.flatMap { event in
            (document.groupsByEvent[event] ?? []).enumerated().flatMap { groupIndex, group in
                group.handlers.enumerated().compactMap { handlerIndex, handler -> OwnedCodexHook? in
                    guard ProviderHookOwnership.classify(handler, layout: layout) != .foreign,
                        case .command(let command) = handler
                    else { return nil }
                    return OwnedCodexHook(
                        event: event, groupIndex: groupIndex, handlerIndex: handlerIndex, group: group, handler: command
                    )
                }
            }
        }
        guard !owned.isEmpty else { return }
        let observedVersion: String?
        if let reader = props.codexVersion {
            observedVersion = reader()
        } else {
            observedVersion = CodexVersionProbe.read(environment: props.environment)
        }
        guard let version = observedVersion else {
            problems.append(.codexTrustUnknown(reason: .versionUnavailable))
            return
        }
        guard CodexHookTrustHash.supports(version: version) else {
            problems.append(.codexTrustUnknown(reason: .unsupportedVersion(version)))
            return
        }
        for entry in owned {
            let event = entry.event
            let key = CodexHookReviewStateReader.key(
                path: layout.hookFileURL.path, event: event, group: entry.groupIndex, handler: entry.handlerIndex)
            let state = review.states[key]
            do {
                let current = try CodexHookTrustHash.hash(event: event, group: entry.group, handler: entry.handler)
                problems.append(contentsOf: (state ?? .init()).problems(currentHash: current, event: event, key: key))
            } catch { problems.append(.codexTrustUnknown(reason: .stateUnreadable(path: config.path))) }
        }
    }
}
