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

/// FIT-338: what a client wrote since the coach last looked, and a coach's notification opening that client.
@MainActor
struct UnreadTests {
    private func at(_ hour: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour))! }

    @Test func countsTheClientsRepliesAndNotesAfterTheMark() {
        let log = SyncUnits.encode([
            SyncUnits.LogRow(id: UUID(), kind: .workout, at: at(9), plannedRef: nil, template: "back-squat", measurements: [], note: "Lower A"),
            SyncUnits.LogRow(id: UUID(), kind: .workout, at: at(9), plannedRef: nil, template: nil, measurements: [], note: "Knee's sore"),
            SyncUnits.LogRow(id: UUID(), kind: .bodyweight, at: at(7), plannedRef: nil, template: nil, measurements: [], note: "Slept badly"),
        ])
        let comments = [
            Triage.Comment(day: "2026-11-10", at: "2026-11-10T15:00:00.000Z", by: "ann", byName: "Ann", text: "Thanks!"),
            Triage.Comment(day: "2026-11-10", at: "2026-11-10T15:30:00Z", by: "coach", byName: "Dana", text: "Rest it"),
        ]
        let units = ["log#2026-11-10": log]
        #expect(Roster.unread(units, comments: comments, from: "ann", since: at(0)) == 3)   // the reply and both notes, not the sets
        #expect(Roster.unread(units, comments: comments, from: "ann", since: at(8)) == 2)   // the check-in was before the mark
        #expect(Roster.unread(units, comments: comments, from: "ann", since: .distantFuture) == 0)
    }

    @Test func aCoachsNotificationNamesTheClientAndDay() {
        let target = PushTarget(["kind": "client", "client": "ann", "day": "2026-11-08"])
        #expect(target?.kind == .client)
        #expect(target?.client == "ann")
        #expect(target?.day.map { SyncUnits.day($0) } == "2026-11-08")
    }
}

/// FIT-340: the client's conversation names each day as Messages does.
@MainActor
struct CoachConversationTests {
    @Test func daysReadTodayYesterdayThenTheDate() {
        let calendar = Calendar.current
        let today = SyncUnits.day(.now)
        let yesterday = SyncUnits.day(calendar.date(byAdding: .day, value: -1, to: .now)!)
        let older = calendar.date(byAdding: .day, value: -9, to: .now)!
        #expect(CoachConversation.title(today) == "Today")
        #expect(CoachConversation.title(yesterday) == "Yesterday")
        #expect(CoachConversation.title(SyncUnits.day(older)) == older.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
    }
}
