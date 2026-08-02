import Foundation
import SwiftData

/// Compact ~12-hour context the notification generator sees. Reuses
/// `CoachContextBuilder` for the shared profile/goals/today/sleep/memory blocks
/// and adds a rolling 12h HR/SpO₂ window plus the slot.
///
/// Each notification is generated **independently** — we deliberately do *not*
/// thread prior check-ins through this packet. The dedup window for "don't
/// schedule two of the same slot in one day" lives in `isDuplicate`.
struct NotificationContextPacket: Encodable {
    var slot: String
    var generatedAt: String
    var timezone: String
    var profileName: String?
    var goals: CoachContextPacket.GoalContext
    var today: CoachContextPacket.DayContext
    var latestSleep: CoachContextPacket.SleepContext?
    var latestVitals: CoachContextPacket.VitalsContext
    var hrLast12h: CoachDataAccess.Stats
    var spo2Last12h: CoachDataAccess.Stats
    var recentWorkouts: [CoachContextPacket.WorkoutContext]
    var memories: [CoachContextPacket.MemoryContext]
    var dataQualityWarnings: [String]
    var environment: CoachContextPacket.EnvironmentContext?
    /// Present only when nutrition tracking is on, shared with the coach, AND the
    /// check-in sub-toggle allows it.
    var nutrition: CoachContextPacket.NutritionContext?
    /// Present only when readiness is on, shared with the coach, AND the check-in
    /// sub-toggle allows it. Same three-gate shape as `nutrition`.
    var readiness: ReadinessContext?

    /// Readiness for a check-in: this morning in the same shape the chat coach sees, plus the
    /// recent scores it should be read against.
    ///
    /// The trailing window is notification-only. The chat coach reaches history through
    /// `get_readiness`, but a push notification is generated in one shot with no tool call
    /// available to it — so the history a "you're down from your usual" line needs has to arrive
    /// in the packet or not at all. It is also what `CoachAnomalyDetector` measures a drop against.
    struct ReadinessContext: Encodable {
        var today: CoachContextPacket.ReadinessContext
        /// Scored mornings *before* today, most recent first. Empty until history exists.
        var recentScores: [Int]
    }
}

@MainActor
enum NotificationContextBuilder {
    static func build(
        slot: CoachNotificationSlot, context: ModelContext, now: Date = Date(),
        environment: CoachContextPacket.EnvironmentContext? = nil
    ) -> NotificationContextPacket {
        // Check-ins honor their own nutrition and readiness sub-toggles on top of the
        // share-with-coach gate each feature already applies.
        let packet = CoachContextBuilder.build(
            context: context, now: now,
            includeNutrition: NutritionPrefsStore.shared.prefs.includeInNotifications,
            includeReadiness: ReadinessPrefsStore.shared.prefs.includeInNotifications
        )
        let cutoff = now.addingTimeInterval(-12 * 3600)

        // Windowed DB queries for the last 12h instead of fetching the whole table and filtering.
        let hr = MetricsRepository.measurements(kind: .heartRate, start: cutoff, end: now, context: context)
            .map(\.value)
        let spo2 = MetricsRepository.measurements(kind: .spo2, start: cutoff, end: now, context: context)
            .map(\.value)

        return NotificationContextPacket(
            slot: slot.rawValue,
            generatedAt: CoachDataAccess.isoString(now),
            timezone: TimeZone.current.identifier,
            profileName: packet.profile.name,
            goals: packet.goals,
            today: packet.today,
            latestSleep: packet.latestSleep,
            latestVitals: packet.latestVitals,
            hrLast12h: CoachDataAccess.stats(hr),
            spo2Last12h: CoachDataAccess.stats(spo2),
            recentWorkouts: packet.recentWorkouts,
            memories: packet.memories,
            dataQualityWarnings: packet.dataQualityWarnings,
            environment: environment,
            nutrition: packet.nutrition,
            readiness: packet.readiness.map {
                NotificationContextPacket.ReadinessContext(
                    today: $0,
                    recentScores: recentReadinessScores(before: now, context: context)
                )
            }
        )
    }

    /// How far back the check-in's readiness history reaches. Two weeks is enough for a median to
    /// mean something without letting a month-old training block define "typical".
    static let readinessHistoryDays = 14

    /// Scored mornings before `now`, most recent first.
    ///
    /// Today is excluded on purpose. This window is the reference this morning gets compared
    /// against, and leaving today inside it would damp the very deviation the comparison exists to
    /// notice — most visibly when history is short, where one of seven samples *is* the outlier.
    private static func recentReadinessScores(before now: Date, context: ModelContext) -> [Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -readinessHistoryDays, to: today),
              let end = calendar.date(byAdding: .day, value: -1, to: today) else { return [] }
        // Rows are stored keyed to `startOfDay`, so an inclusive `end` of yesterday's start
        // captures yesterday and stops short of today.
        return Array(
            ReadinessRepository.rows(from: start, to: end, context: context)
                .map(\.score)
                .reversed()
        )
    }
}
