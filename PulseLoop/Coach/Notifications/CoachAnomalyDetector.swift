import Foundation

/// A notable, gently-actionable pattern detected in the user's recent data.
enum CoachAnomalyKind: String, Codable, Equatable {
    case lowSpO2
    /// This morning's readiness well below the user's own recent typical.
    case readinessDrop
    case poorSleep
    /// Reserved for a future baseline-aware detector (needs multi-day history).
    case restingHRDrift
}

struct CoachAnomaly: Equatable {
    let kind: CoachAnomalyKind
    /// Short, factual, already-grounded description used both for the prompt and
    /// the deterministic fallback copy.
    let facts: String

    /// Once-per-kind-per-day dedupe key (stored as a notification record slot).
    var dedupeKey: String { "anomaly:\(kind.rawValue)" }
}

/// Pure, conservative anomaly detection over the notification context packet.
/// Thresholds are intentionally cautious — a missed alert is far better than a
/// false alarm on health data. Returns at most one anomaly, highest-priority
/// first. (Resting-HR drift is deferred — it needs a multi-day baseline the
/// 12-hour packet doesn't carry.)
enum CoachAnomalyDetector {
    static func detect(_ packet: NotificationContextPacket) -> CoachAnomaly? {
        // 1. Low SpO₂ — most clinically meaningful. Require a few readings so a
        //    single noisy sample doesn't trigger an alert.
        if packet.spo2Last12h.count >= 3, let lowest = packet.spo2Last12h.min, lowest < 90 {
            let pct = Int(lowest.rounded())
            return CoachAnomaly(
                kind: .lowSpO2,
                facts: "The lowest blood-oxygen reading in the last 12 hours was \(pct)%, below the typical 95–100% range."
            )
        }

        // 2. Sharp readiness drop. Ordered above short sleep deliberately: sleep is 30 of
        //    readiness's 100 points, so a bad night usually trips both, and when it does the
        //    readiness alert is the better of the two — it names the largest contributor using the
        //    explanation the app actually computed, rather than asserting sleep was the cause.
        //    `detect` returns at most one anomaly, so this is a precedence choice between two
        //    messages about the same night, not an extra notification.
        if let drop = readinessDrop(packet) { return drop }

        // 3. Short sleep — fires after a sleep download, when it's most relevant.
        if let sleep = packet.latestSleep, (1..<300).contains(sleep.totalMin) {
            let h = sleep.totalMin / 60, m = sleep.totalMin % 60
            let target = packet.goals.sleepHours
            return CoachAnomaly(
                kind: .poorSleep,
                facts: "Last night's sleep was \(h)h \(m)m, well under the \(Int(target))h target."
            )
        }

        return nil
    }

    // MARK: - Readiness drop

    /// How far below the recent median this morning must sit before it's worth interrupting for.
    /// 15 points is roughly a full band, so the drop is one the user would notice looking at the
    /// tile — not a number only a detector can see.
    static let readinessDropPoints: Double = 15
    /// …judged against at least this many prior scored mornings, so the reference isn't itself
    /// noise. Matches the 7-day floor `BaselineStats.isEstablished` already uses for trustworthiness.
    static let readinessDropMinHistory = 7
    /// …on a night at least this well captured. Deliberately stricter than the 0.5 coverage
    /// `ReadinessScore` needs to produce a number at all: rendering a score in a tile the user
    /// chose to open is a lower-stakes act than pushing an unprompted alert about it, and a
    /// half-measured night depresses the score for reasons that have nothing to do with recovery.
    static let readinessDropMinCoverage: Double = 0.7

    /// Fires when this morning's readiness sits well below the user's own recent typical *and*
    /// lands somewhere that actually warrants easing off.
    ///
    /// Four gates, all required, because this is the only detector reading a *derived* number: a
    /// score is no more trustworthy than the night behind it, and an alert that cries wolf about
    /// recovery trains the user to dismiss the ones that matter.
    private static func readinessDrop(_ packet: NotificationContextPacket) -> CoachAnomaly? {
        guard let readiness = packet.readiness else { return nil }
        let today = readiness.today

        guard today.coverage >= readinessDropMinCoverage,
              readiness.recentScores.count >= readinessDropMinHistory,
              let typical = median(readiness.recentScores) else { return nil }

        let drop = typical - Double(today.score)
        guard drop >= readinessDropPoints else { return nil }

        // A fall from 98 to 80 is still a good morning. Only speak up when the score landed
        // somewhere the user might reasonably act on.
        guard let band = ReadinessBand(rawValue: today.band), band == .moderate || band == .restNeeded else {
            return nil
        }

        var facts = "Readiness is \(today.score) this morning (\(today.band.lowercased())), "
            + "\(Int(drop.rounded())) points below the recent typical of \(Int(typical.rounded()))."
        // The app already computed *why*. Handing that over means the alert cites a real reason
        // instead of leaving the generator to guess at one.
        if let lead = today.contributors
            .filter({ $0.pointsEarned < $0.pointsPossible })
            .max(by: { ($0.pointsPossible - $0.pointsEarned) < ($1.pointsPossible - $1.pointsEarned) }) {
            facts += " The largest factor was: \(lead.detail)."
        }
        return CoachAnomaly(kind: .readinessDrop, facts: facts)
    }

    /// Median rather than mean: one washed-out morning — a night the ring only half-recorded —
    /// shouldn't drag the reference that every later drop is measured against.
    private static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[mid - 1] + sorted[mid]) / 2
            : Double(sorted[mid])
    }
}
