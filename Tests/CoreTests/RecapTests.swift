import Foundation
import Testing
@testable import AICoach

/// FIT-108: what a shared week says, and what it sends.
struct RecapTests {
    private let week6 = Recap(week: 6, weeks: 12, phase: "build", done: 3, planned: 3, bests: 2,
                              lifts: [.init(name: "Bench press", from: 190, to: 205, unit: "lb")])

    @Test func withWeightsTheChangeIsInPounds() throws {
        #expect(week6.change(week6.lifts[0], showNumbers: true) == "+15 lb")
        let payload = week6.payload(showNumbers: true)
        #expect(payload["week"] as? Int == 6)
        #expect((payload["sessions"] as? [String: Int])?["done"] == 3)
        #expect(try JSONSerialization.data(withJSONObject: payload).isEmpty == false)
    }

    @Test func withWeightsHiddenNoneAreSent() throws {
        #expect(week6.change(week6.lifts[0], showNumbers: false) == "+8%")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: week6.payload(showNumbers: false)), as: UTF8.self)
        #expect(!json.contains("205") && !json.contains("190"))
    }

    @Test func theLastWeekIsTheProgramsRecap() {
        var last = week6
        last.week = 12
        #expect(last.finished)
        #expect(!week6.finished)
    }
}
