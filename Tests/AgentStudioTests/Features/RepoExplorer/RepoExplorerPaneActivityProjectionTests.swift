import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Repo Explorer pane activity projection")
struct RepoExplorerPaneActivityProjectionTests {
    @Test("one activity time determines the clock, Active, and both bucket sets")
    func sameTimeDrivesEveryPresentation() {
        let samples = [
            (
                age: 59,
                clock: "Now",
                unpinned: RepoExplorerActivityBucket.active,
                pinned: RepoExplorerPinnedActivityBucket.active
            ),
            (age: 60, clock: "1m", unpinned: .justNow, pinned: .recent),
            (age: 599, clock: "9m", unpinned: .justNow, pinned: .recent),
            (age: 600, clock: "10m", unpinned: .lastHour, pinned: .recent),
            (age: 3599, clock: "59m", unpinned: .lastHour, pinned: .recent),
            (age: 3600, clock: "1h", unpinned: .today, pinned: .older),
            (age: 604_800, clock: "7d", unpinned: .older, pinned: .older),
        ]
        let referenceInstant = ContinuousClock.now
        let wallNow = Date(timeIntervalSince1970: 1_769_000_000)
        for sample in samples {
            let time = PaneActivityTime(
                orderingInstant: referenceInstant.advanced(by: .seconds(-sample.age)),
                wallTime: Date(timeIntervalSince1970: 10),
                source: .terminal
            )
            let result = RepoExplorerPaneActivityProjection.make(
                time: time,
                referenceInstant: referenceInstant,
                wallNow: wallNow,
                calendar: utcCalendar
            )

            #expect(result.clockText == sample.clock)
            #expect(result.isActive == (sample.age < 60))
            #expect(result.unpinnedBucket == sample.unpinned)
            #expect(result.pinnedBucket == sample.pinned)
        }
    }

    @Test("unknown time is not Active and has an empty clock")
    func unknownTimeHasNoActivity() {
        let result = RepoExplorerPaneActivityProjection.make(
            time: nil,
            referenceInstant: ContinuousClock.now,
            wallNow: Date(timeIntervalSince1970: 1_769_000_000),
            calendar: utcCalendar
        )

        #expect(result.clockText == "—")
        #expect(!result.isActive)
        #expect(!result.isStreaming)
        #expect(result.nextPresentationChangeDate == nil)
        #expect(result.unpinnedBucket == .noActivity)
        #expect(result.pinnedBucket == .older)
    }

    @Test("a backward wall step does not change age, clock, or bucket")
    func wallStepDoesNotMoveActivity() {
        let referenceInstant = ContinuousClock.now
        let time = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-300)),
            wallTime: Date(timeIntervalSince1970: 1),
            source: .hook
        )
        let wallNow = Date(timeIntervalSince1970: 1_769_000_000)
        let before = RepoExplorerPaneActivityProjection.make(
            time: time,
            referenceInstant: referenceInstant,
            wallNow: wallNow,
            calendar: utcCalendar
        )
        let after = RepoExplorerPaneActivityProjection.make(
            time: time,
            referenceInstant: referenceInstant,
            wallNow: wallNow.addingTimeInterval(-3600),
            calendar: utcCalendar
        )

        #expect(after.age == before.age)
        #expect(after.clockText == before.clockText)
        #expect(after.unpinnedBucket == before.unpinnedBucket)
        #expect(after.pinnedBucket == before.pinnedBucket)
    }

    @Test("local midnight moves Today to Last 7 days")
    func midnightChangesOnlyCalendarBucket() {
        let referenceInstant = ContinuousClock.now
        let beforeMidnight = utcDate(year: 2026, month: 1, day: 15, hour: 23, minute: 59)
        let time = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-7200)),
            wallTime: Date(timeIntervalSince1970: 1),
            source: .terminal
        )
        let before = RepoExplorerPaneActivityProjection.make(
            time: time,
            referenceInstant: referenceInstant,
            wallNow: beforeMidnight,
            calendar: utcCalendar
        )
        let after = RepoExplorerPaneActivityProjection.make(
            time: time,
            referenceInstant: referenceInstant.advanced(by: .seconds(60)),
            wallNow: beforeMidnight.addingTimeInterval(60),
            calendar: utcCalendar
        )

        #expect(before.unpinnedBucket == .today)
        #expect(after.unpinnedBucket == .lastSevenDays)
        #expect(before.pinnedBucket == .older)
        #expect(after.pinnedBucket == .older)
    }

    @Test("worker row facts ignore focus and interaction recency")
    func workerUsesOnlyPublishedActivityTime() {
        let referenceInstant = ContinuousClock.now
        let wallNow = utcDate(year: 2026, month: 1, day: 15, hour: 12, minute: 0)
        let activeTime = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-120)),
            wallTime: Date(timeIntervalSince1970: 1),
            source: .hook
        )
        let timedPaneID = UUIDv7.generate()
        let unknownPaneID = UUIDv7.generate()
        let captured: [UUID: RepoExplorerPaneRowFacts] = [
            timedPaneID: RepoExplorerPaneRowFacts(
                terminalTitle: "timed",
                activityAt: wallNow.addingTimeInterval(-7200),
                paneActivityTime: activeTime,
                latestMessageText: nil,
                recencyReferenceDate: wallNow,
                recencyText: "Now",
                isActive: true
            ),
            unknownPaneID: RepoExplorerPaneRowFacts(
                terminalTitle: "unknown",
                activityAt: wallNow,
                latestMessageText: nil,
                recencyReferenceDate: wallNow,
                recencyText: "Now",
                isActive: true
            ),
        ]
        let snapshot = RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            surface: .panes,
            groupingMode: .activity,
            referenceDate: wallNow,
            referenceInstant: referenceInstant,
            calendar: utcCalendar,
            query: ""
        )

        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(captured, snapshot: snapshot)

        #expect(prepared[timedPaneID]?.recencyText == "2m")
        #expect(prepared[timedPaneID]?.isActive == false)
        #expect(prepared[timedPaneID]?.activityAt == wallNow.addingTimeInterval(-120))
        #expect(prepared[unknownPaneID]?.recencyText == "—")
        #expect(prepared[unknownPaneID]?.isActive == false)
        #expect(prepared[unknownPaneID]?.activityAt == nil)
    }

    @Test("Panes sections use activity buckets even when old grouping preferences say Repo")
    func panesSectionsUseOneActivityBasis() {
        let referenceInstant = ContinuousClock.now
        let wallNow = utcDate(year: 2026, month: 1, day: 15, hour: 12, minute: 0)
        let tabID = UUIDv7.generate()
        let pinnedActiveID = UUIDv7.generate()
        let pinnedRecentID = UUIDv7.generate()
        let pinnedOlderID = UUIDv7.generate()
        let unpinnedRecentID = UUIDv7.generate()
        let unpinnedUnknownID = UUIDv7.generate()
        let paneIDs = [pinnedActiveID, pinnedRecentID, pinnedOlderID, unpinnedRecentID, unpinnedUnknownID]
        let snapshot = RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            surface: .panes,
            groupingMode: .repo,
            referenceDate: wallNow,
            referenceInstant: referenceInstant,
            calendar: utcCalendar,
            query: "",
            unassociatedPaneLocations: paneIDs.enumerated().map { index, paneID in
                WorkspacePaneLocation(
                    paneId: paneID,
                    tabId: tabID,
                    tabIndex: 0,
                    paneIndexInTab: index,
                    isActiveInTab: index == 4
                )
            }
        )
        func facts(_ title: String, pinned: Bool, age: Int?) -> RepoExplorerPaneRowFacts {
            RepoExplorerPaneRowFacts(
                terminalTitle: title,
                paneActivityTime: age.map { seconds in
                    PaneActivityTime(
                        orderingInstant: referenceInstant.advanced(by: .seconds(-seconds)),
                        wallTime: Date(timeIntervalSince1970: 1),
                        source: .terminal
                    )
                },
                isPinned: pinned,
                latestMessageText: nil,
                recencyReferenceDate: .distantPast,
                recencyText: "",
                isActive: false
            )
        }
        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
            [
                pinnedActiveID: facts("active", pinned: true, age: 30),
                pinnedRecentID: facts("recent", pinned: true, age: 1800),
                pinnedOlderID: facts("older", pinned: true, age: nil),
                unpinnedRecentID: facts("just now", pinned: false, age: 120),
                unpinnedUnknownID: facts("unknown", pinned: false, age: nil),
            ],
            snapshot: snapshot
        )

        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)

        #expect(projection.sections.map(\.kind) == [.pinnedPanes, .panes])
        #expect(projection.sections[0].resolvedGroups.map(\.repoTitle) == ["Active", "Recent", "Older"])
        #expect(projection.sections[1].resolvedGroups.map(\.repoTitle) == ["Just Now", "No activity"])
        #expect(projection.sections[0].title == "Pinned Panes")
        #expect(projection.sections[1].title == "Panes")
    }

    @Test(
        "streaming ends exactly at the 12-second publication window",
        arguments: [
            (0.0, true), (10.0, true), (11.999, true), (12.0, false), (12.001, false), (60.0, false),
        ])
    func streamingUsesActivityAge(ageSeconds: Double, expectedStreaming: Bool) {
        let referenceInstant = ContinuousClock.now
        let time = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-ageSeconds)),
            wallTime: .distantPast, source: .terminal)

        let result = RepoExplorerPaneActivityProjection.make(
            time: time, referenceInstant: referenceInstant,
            wallNow: Date(timeIntervalSince1970: 1_769_000_000), calendar: utcCalendar)

        #expect(result.isStreaming == expectedStreaming)
    }

    @Test("streaming lapse wins the presentation deadline, then the clock boundary resumes")
    func streamingLapseSchedulesPresentationChange() {
        let referenceInstant = ContinuousClock.now
        let wallNow = utcDate(year: 2026, month: 1, day: 15, hour: 12, minute: 0)
        let time = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-11)),
            wallTime: .distantPast, source: .terminal)

        let streaming = RepoExplorerPaneActivityProjection.make(
            time: time, referenceInstant: referenceInstant, wallNow: wallNow, calendar: utcCalendar)
        let lapsed = RepoExplorerPaneActivityProjection.make(
            time: time, referenceInstant: referenceInstant.advanced(by: .seconds(1)),
            wallNow: wallNow.addingTimeInterval(1), calendar: utcCalendar)

        #expect(streaming.isStreaming)
        #expect(streaming.nextPresentationChangeDate == wallNow.addingTimeInterval(1))
        #expect(!lapsed.isStreaming)
        #expect(lapsed.nextPresentationChangeDate == wallNow.addingTimeInterval(49))
        #expect(lapsed.clockText == streaming.clockText)
        #expect(lapsed.isActive == streaming.isActive)
        #expect(lapsed.unpinnedBucket == streaming.unpinnedBucket)
        #expect(lapsed.pinnedBucket == streaming.pinnedBucket)
    }

    @Test("terminal activity without an agent carries streaming and its deadline into the row")
    func workerThreadsStreamingIntoPaneRow() throws {
        let referenceInstant = ContinuousClock.now
        let wallNow = utcDate(year: 2026, month: 1, day: 15, hour: 12, minute: 0)
        let paneID = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes,
            referenceDate: wallNow, referenceInstant: referenceInstant, calendar: utcCalendar, query: "",
            unassociatedPaneLocations: [
                WorkspacePaneLocation(
                    paneId: paneID, tabId: UUIDv7.generate(), tabIndex: 0, paneIndexInTab: 0, isActiveInTab: false)
            ])
        let captured = RepoExplorerPaneRowFacts(
            terminalTitle: "Terminal",
            paneActivityTime: PaneActivityTime(
                orderingInstant: referenceInstant.advanced(by: .seconds(-10)),
                wallTime: .distantPast, source: .terminal),
            latestMessageText: nil, recencyReferenceDate: .distantPast, recencyText: "—", isActive: false)

        let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts([paneID: captured], snapshot: snapshot)
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: prepared)
        let row = try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(prepared[paneID]?.isStreaming == true)
        #expect(prepared[paneID]?.nextPresentationChangeDate == wallNow.addingTimeInterval(2))
        #expect(row.isStreaming)
        #expect(row.recencyText == "Now")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
