import Foundation
import Testing
@testable import AICoach

/// FIT-220: the coaching notifications' data, as infra/lambda/push.ts and nudge.ts send it.
struct PushTargetTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func eachKindOpensItsDay() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))
        #expect(PushTarget(["kind": "plan", "day": "2026-10-23"], calendar: calendar) == PushTarget(kind: .plan, day: day))
        #expect(PushTarget(["kind": "nudge", "day": "2026-10-23"], calendar: calendar) == PushTarget(kind: .nudge, day: day))
        #expect(PushTarget(["kind": "reply", "day": "2026-10-23", "aps": [:]], calendar: calendar) == PushTarget(kind: .reply, day: day))
        #expect(PushTarget(["kind": "offer", "offer": "1"], calendar: calendar) == PushTarget(kind: .offer, day: nil))
    }

    @Test func anythingElseIsntOne() {
        #expect(PushTarget(["groupId": "g1"]) == nil)
        #expect(PushTarget(["kind": "live"]) == nil)
        #expect(PushTarget(["kind": "plan", "day": "soon"])?.day == nil)
    }
}
