#if DEBUG
import Foundation

/// FIT-298: `-sampleClients YES` opens coach mode on three made-up clients, to look at it without a coach's account.
extension Roster {
    static var sample: Bool { UserDefaults.standard.bool(forKey: "sampleClients") }

    static func samples() -> [Client] {
        let calendar = Calendar.current
        func day(_ offset: Int) -> String { SyncUnits.day(calendar.date(byAdding: .day, value: offset, to: .now)!) }
        func at(_ offset: Int) -> Double {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!.timeIntervalSince1970 + 18 * 3600
        }
        func json(_ rows: [[String: Any]]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self) }
        func target(_ metric: String, _ value: Double, _ unit: String) -> [String: Any] { ["metric": metric, "value": value, "unit": unit] }
        func plan(_ offset: Int, _ lifts: [(String, Double?)]) -> (String, String) {
            ("plan#\(day(offset))", json(lifts.enumerated().map { index, lift in
                ["id": UUID().uuidString, "kind": "workout", "at": at(offset) + Double(index), "slot": "Lower", "template": lift.0,
                 "targets": [target("sets", 3, "sets"), target("reps", 5, "reps")] + (lift.1.map { [target("load_lb", $0, "lb")] } ?? []),
                 "note": "", "main": index == 0, "pinned": true]
            }))
        }
        func log(_ offset: Int, _ slug: String, _ sets: [(Double, Double, Double?)], note: String?) -> (String, String) {
            var rows: [[String: Any]] = sets.enumerated().map { index, set in
                ["id": UUID().uuidString, "kind": "workout", "at": at(offset) + Double(index), "template": slug, "note": "Lower A",
                 "measurements": [target("reps", set.1, "reps"), target("load_lb", set.0, "lb")] + (set.2.map { [target("rpe", $0, "RPE")] } ?? [])]
            }
            if let note { rows.append(["id": UUID().uuidString, "kind": "workout", "at": at(offset) + 9, "note": note, "measurements": []]) }
            return ("log#\(day(offset))", json(rows))
        }
        let names = ["back-squat": "Back Squat", "bench-press": "Bench Press", "romanian-deadlift": "Romanian Deadlift"]
        func client(_ name: String, _ pairs: [(String, String)]) -> Client {
            let units = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
            return Client(person: Cloud.Person(uid: name, name: name, since: ""), units: units, comments: [],
                          week: Triage.week(units, comments: [], names: names, coach: "", today: day(0)))
        }
        return [
            client("Mike Torres", [plan(-2, [("back-squat", 245)]),
                                   log(-2, "back-squat", [(245, 5, nil), (245, 5, nil), (245, 3, 9)], note: "Knee’s sore on squats. Stopped the last set at 3."),
                                   plan(0, [("back-squat", 245), ("romanian-deadlift", 185)])]),
            client("Sara Kim", [plan(-4, [("bench-press", 135)]), plan(-1, [("bench-press", 135)]), plan(1, [("bench-press", 140)])]),
            client("Tom Reyes", [plan(-3, [("bench-press", 185)]), log(-3, "bench-press", [(185, 5, 8), (185, 5, 8), (185, 5, 8)], note: nil),
                                 plan(2, [("bench-press", 190)])]),
        ]
    }
}
#endif
