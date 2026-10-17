import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

enum RepoExplorerPinnedActivityBucket: Int, CaseIterable, Equatable, Sendable {
    case active
    case recent
    case older

    var title: String {
        switch self {
        case .active: "Active"
        case .recent: "Recent"
        case .older: "Older"
        }
    }
}

/// One derivation from the clock's monotonic occurrence and one capture reference pair.
/// The derived wall date is used only to answer local-calendar questions.
struct RepoExplorerPaneActivityProjection: Equatable, Sendable {
    let age: Duration?
    let activityDate: Date?
    let clockText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let unpinnedBucket: RepoExplorerActivityBucket
    let pinnedBucket: RepoExplorerPinnedActivityBucket
    let nextPresentationChangeDate: Date?

    static func make(
        time: PaneActivityTime?,
        referenceInstant: ContinuousClock.Instant,
        wallNow: Date,
        calendar: Calendar
    ) -> Self {
        guard let time else {
            return Self(
                age: nil,
                activityDate: nil,
                clockText: "—",
                recencyTier: .grey,
                isActive: false,
                unpinnedBucket: .noActivity,
                pinnedBucket: .older,
                nextPresentationChangeDate: nil
            )
        }

        let age = max(.zero, time.orderingInstant.duration(to: referenceInstant))
        let components = age.components
        let ageSeconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let activityDate = wallNow.addingTimeInterval(-ageSeconds)
        let unpinnedBucket = RepoExplorerActivityBucket.classify(
            activityAt: activityDate,
            now: wallNow,
            calendar: calendar
        )
        let pinnedBucket: RepoExplorerPinnedActivityBucket =
            if ageSeconds < AppPolicies.RepoExplorer.activeActivityDuration {
                .active
            } else if ageSeconds < AppPolicies.RepoExplorer.lastHourActivityDuration {
                .recent
            } else {
                .older
            }
        let nextClockChange = RepoExplorerPaneRecencyText.nextPresentationChangeDate(
            referenceDate: activityDate,
            now: wallNow
        )
        let nextBucketChange = RepoExplorerActivityBucket.nextChangeDate(
            activityAt: activityDate,
            now: wallNow,
            calendar: calendar
        )
        let nextPresentationChangeDate = [nextClockChange, nextBucketChange].compactMap(\.self).min()

        return Self(
            age: age,
            activityDate: activityDate,
            clockText: RepoExplorerPaneRecencyText.display(lastInteractedAt: activityDate, now: wallNow),
            recencyTier: RepoExplorerPaneRecencyTier.classify(referenceDate: activityDate, now: wallNow),
            isActive: pinnedBucket == .active,
            unpinnedBucket: unpinnedBucket,
            pinnedBucket: pinnedBucket,
            nextPresentationChangeDate: nextPresentationChangeDate
        )
    }
}
