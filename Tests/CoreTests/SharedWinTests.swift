import Foundation
import Testing
@testable import AICoach

/// FIT-107: what's saved when a win is shared.
struct SharedWinTests {
    private let best = WinItem(kind: .pr, date: Date(timeIntervalSince1970: 1_791_590_400), key: "pr:bench:205", metric: "bench-press.1rm_lb",
                               unit: "lb", value: 205, previous: 190, trend: [175, 190, 205])

    @Test func withWeightsTheNumbersGo() throws {
        let payload = SharedWin.payload(best, style: .paper, showNumbers: true)
        #expect(payload["kind"] as? String == "pr")
        #expect(payload["metric"] as? String == "Bench press")
        #expect(payload["value"] as? Double == 205)
        #expect(payload["previous"] as? Double == 190)
        #expect(payload["style"] as? String == "paper")
        #expect(try JSONSerialization.data(withJSONObject: payload).isEmpty == false)
    }

    @Test func withWeightsHiddenNoneAreSent() throws {
        let payload = SharedWin.payload(best, style: .dark, showNumbers: false)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        for weight in ["205", "190", "175"] { #expect(!json.contains(weight)) }
        // The page still shows "+8%": 205 is 107.9% of 190.
        #expect(payload["value"] as? Double == 107.9)
        #expect(payload["previous"] as? Double == 100)
    }

    @Test func aHiddenMilestoneIsItsPercent() {
        let milestone = WinItem(kind: .milestone, date: .now, key: "m", metric: "bench-press.1rm_lb", unit: "lb", value: 170, target: 225, percent: 75)
        let payload = SharedWin.payload(milestone, style: .dark, showNumbers: false)
        #expect(payload["value"] as? Double == 75)
        #expect(payload["target"] as? Double == 100)
        #expect(payload["metric"] as? String == "bench")
    }
}
