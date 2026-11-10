import Foundation
import Testing
@testable import AICoach

/// FIT-331: coach mode's list A–Z, when each client last logged, and the week shown on a client.
@MainActor
struct RosterTests {
    private func client(_ name: String, units: [String: String] = [:]) -> Roster.Client {
        Roster.Client(person: Cloud.Person(uid: name, name: name, since: ""), units: units, comments: [],
                      week: Triage.Week(done: 0, planned: 0, lastSession: nil, flags: []))
    }

    @Test func sortsByNameIgnoringCase() {
        let sorted = Roster.byName([client("sara Kim"), client("Mike Torres"), client("Ava Lindqvist"), client("Tom 10"), client("Tom 9")])
        #expect(sorted.map(\.name) == ["Ava Lindqvist", "Mike Torres", "sara Kim", "Tom 9", "Tom 10"])
    }

    @Test func lastLoggedIsTheLatestRowOfTheLatestDay() {
        func log(_ times: [Double]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: times.map {
                ["id": UUID().uuidString, "kind": "workout", "at": $0, "template": "back-squat", "note": "", "measurements": []]
            }), as: UTF8.self)
        }
        let units = ["log#2026-11-01": log([1_000]), "log#2026-11-08": log([5_000, 9_000]), "plan#2026-11-12": "[]"]
        #expect(client("Mike", units: units).lastLogged == Date(timeIntervalSince1970: 9_000))
        #expect(client("New").lastLogged == nil)
    }

    @Test func conversationHasEveryDayEitherOfThemWroteOnAndTheDayOpened() {
        let note = String(decoding: try! JSONSerialization.data(withJSONObject: [
            ["id": UUID().uuidString, "kind": "workout", "at": 1_000, "note": "Knee's sore", "measurements": []],
        ]), as: UTF8.self)
        let quiet = String(decoding: try! JSONSerialization.data(withJSONObject: [
            ["id": UUID().uuidString, "kind": "workout", "at": 2_000, "template": "back-squat", "note": "Lower A", "measurements": []],
        ]), as: UTF8.self)
        var mike = client("Mike", units: ["log#2026-11-08": note, "log#2026-11-09": quiet])
        mike.comments = [Triage.Comment(day: "2026-11-03", at: "2026-11-03T18:00:00Z", by: "coach", byName: "Dana", text: "Nice work")]
        #expect(DayThread.days(mike, opened: "2026-11-10") == ["2026-11-03", "2026-11-08", "2026-11-10"])
        #expect(DayThread.days(mike, opened: "2026-11-08") == ["2026-11-03", "2026-11-08"])
    }

    @Test func agoReadsAsMessagesDatesItsRows() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let days = { (n: Int) in calendar.date(byAdding: .day, value: -n, to: now)! }
        #expect(ClientRow.ago(days(3), now: now) == days(3).formatted(.dateTime.weekday(.wide)))
        #expect(ClientRow.ago(days(9), now: now) == days(9).formatted(.dateTime.month(.abbreviated).day()))
    }

    @Test func weekRangeSaysTheMonthOnceUnlessItChanges() {
        let calendar = Calendar.current
        let day = { (m: Int, d: Int) in calendar.date(from: DateComponents(year: 2026, month: m, day: d))! }
        let nov = day(11, 1).formatted(.dateTime.month(.abbreviated))
        let oct = day(10, 26).formatted(.dateTime.month(.abbreviated))
        #expect(WeekPaging.range(day(11, 1)) == "\(nov) 1 – 7")
        #expect(WeekPaging.range(day(10, 26)) == "\(oct) 26 – \(nov) 1")
    }
}
