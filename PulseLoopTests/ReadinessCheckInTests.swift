import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// Readiness reaching the notification surfaces: the daily check-in packet, and the sharp-drop
/// anomaly rule.
///
/// The bar these tests defend is *not* "does the rule fire". It is "does the rule stay quiet".
/// A proactive health alert the user didn't ask for is the most expensive notification the app can
/// send — send a few wrong ones and the user turns the whole category off, taking the alerts that
/// would have mattered with it. So most of what follows asserts silence.

// MARK: - Harness

private func readinessPacket(
    score: Int,
    band: String,
    coverage: Double = 1.0,
    recentScores: [Int],
    contributors: [CoachContextPacket.ReadinessContext.ContributorBrief] = [],
    notMeasured: [String] = [],
    sleepMinutes: Int? = nil,
    spo2: CoachDataAccess.Stats = .init(count: 0, avg: nil, min: nil, max: nil)
) -> NotificationContextPacket {
    NotificationContextPacket(
        slot: "morning", generatedAt: "", timezone: "UTC", profileName: "Sam",
        goals: .init(stepsDaily: 10000, activeMinutesDaily: 45, sleepHours: 8, exerciseDaysWeekly: 4),
        today: .init(localDate: "2026-06-05", steps: 0, calories: nil, distanceKm: nil,
                     activeMinutes: nil, dataConfidence: "high"),
        latestSleep: sleepMinutes.map {
            .init(date: "2026-06-05", totalMin: $0, deepMin: 0, lightMin: $0, awakeMin: 0,
                  score: nil, confidence: "high", decoderNote: "")
        },
        latestVitals: .init(latestHr: nil, latestHrAt: nil, latestSpo2: nil, latestSpo2At: nil,
                            restingHrEstimate: nil, peakHrToday: nil),
        hrLast12h: .init(count: 0, avg: nil, min: nil, max: nil),
        spo2Last12h: spo2,
        recentWorkouts: [], memories: [], dataQualityWarnings: [],
        readiness: .init(
            today: .init(score: score, band: band, coverage: coverage,
                         contributors: contributors, notMeasured: notMeasured),
            recentScores: recentScores
        )
    )
}

/// A settled user who normally scores in the mid-70s — enough history to clear the 7-morning gate.
private let typicalHistory = [76, 74, 79, 73, 77, 75, 78, 74]

private func brief(_ signal: String, earned: Double, possible: Double, detail: String)
-> CoachContextPacket.ReadinessContext.ContributorBrief {
    .init(signal: signal, pointsEarned: earned, pointsPossible: possible, detail: detail)
}

// MARK: - The drop rule (pure)

final class ReadinessDropDetectorTests: XCTestCase {

    func testSharpDropBelowRecentTypicalAlerts() {
        let anomaly = CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", recentScores: typicalHistory)
        )
        XCTAssertEqual(anomaly?.kind, .readinessDrop)
        XCTAssertEqual(anomaly?.dedupeKey, "anomaly:readinessDrop")
    }

    /// The facts string is what the generator is told to ground itself in, so the numbers in it
    /// have to be the real ones — a wrong number here becomes a wrong number in a push notification.
    func testFactsCarryTheScoreTheDropAndTheLargestContributor() throws {
        let anomaly = try XCTUnwrap(CoachAnomalyDetector.detect(
            readinessPacket(
                score: 52, band: "Rest needed", recentScores: typicalHistory,
                contributors: [
                    brief("sleep", earned: 28, possible: 30, detail: "Sleep score 85"),
                    brief("hrv", earned: 9, possible: 30, detail: "HRV 22% below your baseline"),
                ]
            )
        ))
        XCTAssertTrue(anomaly.facts.contains("52"), anomaly.facts)
        // Median of `typicalHistory` is 75.5, so the drop reports as 24 below a typical of 76.
        XCTAssertTrue(anomaly.facts.contains("24 points below"), anomaly.facts)
        XCTAssertTrue(anomaly.facts.contains("typical of 76"), anomaly.facts)
        XCTAssertTrue(anomaly.facts.contains("HRV 22% below your baseline"), anomaly.facts)
        XCTAssertFalse(anomaly.facts.contains("Sleep score 85"),
                       "only the largest drag should be cited, not every contributor")
    }

    /// A contributor that lost nothing is not a reason for anything, and naming it would tell the
    /// generator the cause was something that in fact went fine.
    func testAContributorAtFullPointsIsNeverCitedAsTheCause() throws {
        let anomaly = try XCTUnwrap(CoachAnomalyDetector.detect(
            readinessPacket(
                score: 52, band: "Rest needed", recentScores: typicalHistory,
                contributors: [brief("sleep", earned: 30, possible: 30, detail: "Sleep score 96")]
            )
        ))
        XCTAssertFalse(anomaly.facts.contains("largest factor"), anomaly.facts)
    }

    // MARK: - Staying quiet

    func testNormalDayToDayVariationDoesNotAlert() {
        // 8 points below a 75.5 median — inside ordinary noise.
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 67, band: "Moderate", recentScores: typicalHistory)
        ))
    }

    /// The single most important case here. Someone who normally scores in the high 90s can drop 18
    /// points and still be perfectly recovered; alerting them would be alarming them over nothing.
    func testALargeDropThatLandsInAGoodBandDoesNotAlert() {
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 80, band: "Ready",
                            recentScores: [98, 97, 99, 96, 98, 97, 99, 98])
        ))
    }

    /// A night the ring only half-recorded scores low because signals are missing, not because
    /// recovery is poor. That's a data problem, and pushing it as a health alert is a false alarm.
    func testAPoorlyCapturedNightDoesNotAlert() {
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", coverage: 0.55, recentScores: typicalHistory)
        ))
    }

    func testWithoutEnoughHistoryThereIsNoTypicalToDropFrom() {
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", recentScores: [76, 74, 79])
        ))
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", recentScores: [])
        ))
    }

    /// A user whose readiness is *always* low has not had a bad night — they have a low baseline.
    /// Judging against their own history rather than an absolute cutoff is the whole point.
    func testAConsistentlyLowScorerIsNotAlertedEveryMorning() {
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 48, band: "Rest needed",
                            recentScores: [50, 47, 52, 49, 51, 46, 53, 48])
        ))
    }

    /// Median, not mean: one washed-out morning in the history must not drag the reference far
    /// enough to manufacture a drop out of an ordinary day.
    func testASingleOutlierMorningInHistoryDoesNotSkewTheReference() {
        // Mean of this history is ~68 (one 20 drags it); the median is 75.
        let withOutlier = [76, 74, 79, 20, 77, 75, 78, 74]
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 68, band: "Moderate", recentScores: withOutlier)
        ), "a 68 against a median of 75 is a 7-point drop, not a 15-point one")
    }

    func testNoReadinessBlockMeansNoReadinessAlert() {
        var packet = readinessPacket(score: 52, band: "Rest needed", recentScores: typicalHistory)
        packet.readiness = nil
        XCTAssertNil(CoachAnomalyDetector.detect(packet))
    }

    /// An unrecognised band must fail closed. A stored row from a future build with a band this
    /// version doesn't know should produce silence, not an alert judged on a band check that
    /// silently passed.
    func testAnUnknownBandDoesNotAlert() {
        XCTAssertNil(CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Depleted", recentScores: typicalHistory)
        ))
    }

    // MARK: - Precedence

    /// Sleep is 30 of readiness's 100 points, so a bad night trips both rules. Only one anomaly is
    /// returned, and it should be the one that can name the actual largest factor.
    func testReadinessDropOutranksShortSleep() {
        let anomaly = CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", recentScores: typicalHistory,
                            sleepMinutes: 240)
        )
        XCTAssertEqual(anomaly?.kind, .readinessDrop)
    }

    /// …but short sleep still fires on its own when readiness has nothing to say.
    func testShortSleepStillFiresWhenReadinessIsUnremarkable() {
        let anomaly = CoachAnomalyDetector.detect(
            readinessPacket(score: 74, band: "Ready", recentScores: typicalHistory, sleepMinutes: 240)
        )
        XCTAssertEqual(anomaly?.kind, .poorSleep)
    }

    /// Low blood oxygen is the most clinically meaningful signal in the packet and keeps top
    /// priority — a readiness drop must not displace it.
    func testLowSpO2StillOutranksAReadinessDrop() {
        let anomaly = CoachAnomalyDetector.detect(
            readinessPacket(score: 52, band: "Rest needed", recentScores: typicalHistory,
                            spo2: .init(count: 5, avg: 91, min: 87, max: 95))
        )
        XCTAssertEqual(anomaly?.kind, .lowSpO2)
    }
}

// MARK: - The check-in packet

@MainActor
final class ReadinessCheckInContextTests: XCTestCase {

    private var savedPrefs: ReadinessPrefs?

    override func setUp() async throws {
        try await super.setUp()
        savedPrefs = ReadinessPrefsStore.shared.prefs
        ReadinessPrefsStore.shared.prefs = ReadinessPrefs.default   // on + shared + mentioned
    }

    override func tearDown() async throws {
        if let savedPrefs { ReadinessPrefsStore.shared.prefs = savedPrefs }
        try await super.tearDown()
    }

    private let sampleContributors = #"""
    [{"kindRaw":"hrv","earned":18,"maxPoints":30,"value":44,"baseline":50,"deviation":-12,"detail":"HRV 12% below your baseline"},
     {"kindRaw":"sleep","earned":28,"maxPoints":30,"value":85,"detail":"Sleep score 85"}]
    """#

    @discardableResult
    private func insertScore(_ dayOffset: Int, score: Int, into context: ModelContext) -> ReadinessDaily {
        let row = ReadinessDaily(
            date: TestSupport.day(dayOffset),
            score: score,
            band: ReadinessScore.band(score),
            availablePoints: 85,
            contributorsJSON: sampleContributors
        )
        context.insert(row)
        try? context.save()
        return row
    }

    private func packet(_ context: ModelContext) -> NotificationContextPacket {
        NotificationContextBuilder.build(slot: .morning, context: context)
    }

    func testCheckInCarriesThisMorningAndItsRecentHistory() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 52, into: context)
        for offset in 1...5 { insertScore(-offset, score: 70 + offset, into: context) }

        let readiness = try XCTUnwrap(packet(context).readiness)
        XCTAssertEqual(readiness.today.score, 52)
        XCTAssertEqual(readiness.recentScores, [71, 72, 73, 74, 75],
                       "prior mornings, most recent first")
    }

    /// Today must not appear in the window it is being compared against — including it would damp
    /// the very deviation the comparison exists to notice.
    func testTodayIsExcludedFromItsOwnReferenceWindow() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 52, into: context)
        for offset in 1...8 { insertScore(-offset, score: 75, into: context) }

        let readiness = try XCTUnwrap(packet(context).readiness)
        XCTAssertFalse(readiness.recentScores.contains(52))
        XCTAssertEqual(readiness.recentScores, Array(repeating: 75, count: 8))
    }

    func testHistoryStopsAtTheWindowEdge() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 52, into: context)
        insertScore(-3, score: 70, into: context)
        insertScore(-NotificationContextBuilder.readinessHistoryDays - 1, score: 99, into: context)

        let readiness = try XCTUnwrap(packet(context).readiness)
        XCTAssertEqual(readiness.recentScores, [70], "the out-of-window morning must not appear")
    }

    /// The "Mention in check-ins" toggle existed before this and did nothing. It has to actually
    /// remove readiness from the notification packet while leaving the chat coach untouched.
    func testTheCheckInToggleOffRemovesReadinessFromNotificationsOnly() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        var prefs = ReadinessPrefs.default
        prefs.includeInNotifications = false
        ReadinessPrefsStore.shared.prefs = prefs

        XCTAssertNil(packet(context).readiness)
        XCTAssertNotNil(CoachContextBuilder.build(context: context).readiness,
                        "the chat coach has its own gate and must be unaffected")
    }

    /// Sharing with the coach is the outer gate: turning it off must take check-ins with it, even
    /// though the check-in sub-toggle is still on.
    func testSharingOffAlsoSilencesCheckIns() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        var prefs = ReadinessPrefs.default
        prefs.shareWithCoach = false
        ReadinessPrefsStore.shared.prefs = prefs

        XCTAssertNil(packet(context).readiness)
    }

    func testFeatureOffRemovesReadinessEntirely() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        var prefs = ReadinessPrefs.default
        prefs.masterEnabled = false
        ReadinessPrefsStore.shared.prefs = prefs

        XCTAssertNil(packet(context).readiness)
    }

    /// Absent from the JSON entirely rather than present-and-null, matching how the chat packet
    /// handles it — the model should see no readiness key at all rather than reason about a null.
    func testReadinessIsAbsentFromEncodedJSONWhenSuppressed() throws {
        let context = try TestSupport.makeContext()
        insertScore(0, score: 74, into: context)

        var prefs = ReadinessPrefs.default
        prefs.includeInNotifications = false
        ReadinessPrefsStore.shared.prefs = prefs

        let json = NotificationPromptBuilder.developerMessage(packet: packet(context))
        XCTAssertFalse(json.contains("readiness"), json)
    }

    /// No scored morning yet (a new ring still learning baselines) is not an error state — the
    /// packet simply carries no readiness, and the check-in writes about something else.
    func testNoScoredMorningYieldsNoReadinessBlock() throws {
        let context = try TestSupport.makeContext()
        XCTAssertNil(packet(context).readiness)
    }
}
