import Foundation
import Testing
@testable import AICoach

/// FIT-131: a program a coach sent, as the app reads it.
struct ProgramOfferTests {
    @Test func readsTheWeekInOrderAndDescribesSets() throws {
        let json = #"[{"weekday":4,"slot":"Upper","rows":[{"template":"bench-press","targets":[{"metric":"sets","value":3,"unit":"sets"},{"metric":"reps","value":5,"unit":"reps"},{"metric":"load_lb","value":155,"unit":"lb"}]}]},{"weekday":1,"slot":"Lower","rows":[{"template":"plank","targets":[{"metric":"sets","value":3,"unit":"sets"},{"metric":"duration_s","value":40,"unit":"s"}]}]}]"#
        let offer = Cloud.ProgramOffer(id: "o1", coachUid: "sam", coachName: "Sam", note: "", start: "2026-10-18", weeks: 4,
                                       days: json, addPerWeek: 5, status: "sent")
        #expect(offer.week.map(\.slot) == ["Lower", "Upper"])
        #expect(ProgramOfferSheet.describe(offer.week[1].rows[0].targets) == "3 × 5 @ 155 lb")
        #expect(ProgramOfferSheet.describe(offer.week[0].rows[0].targets) == "3 × 40 s")
        #expect(offer.startDate != nil)
    }
}
