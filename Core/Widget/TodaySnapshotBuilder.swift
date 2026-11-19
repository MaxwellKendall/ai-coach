import Foundation

/// TKL-802: the widget's snapshot from the app's plan and logs, as the pure rules see them (no SwiftData, no UI).
/// `TodayWidget` (Features/Today) reads the store and writes the result.
extension TodaySnapshot {
    /// One day as Today sees it.
    enum Input: Sendable {
        case plan(title: String, session: SessionPlan, minutes: Int)
        case done(title: String, sets: Int, volume: Double, logged: [LoggedSet], at: Date)
        case rest
    }

    /// `name` turns an exercise slug into its name and the word people say for it.
    static func build(_ days: [(date: Date, input: Input)], name: (String) -> (name: String, short: String), starts: [Date],
                      setUp: Bool, plate: String, calendar: Calendar = .current) -> TodaySnapshot {
        let built = days.map { date, input -> Day in
            var day = Day(date: calendar.startOfDay(for: date))
            switch input {
            case .plan(let title, let session, let minutes):
                day.title = title
                day.lifts = lifts(session, name: name)
                day.minutes = minutes
                day.usual = usual(on: date, starts: starts, calendar: calendar)
            case .done(let title, let sets, let volume, let logged, let at):
                day.title = title
                day.done = Done(sets: sets, volume: volume, best: best(logged, name: name), at: at)
            case .rest:
                break
            }
            return day
        }
        return TodaySnapshot(setUp: setUp, plate: plate, days: built)
    }

    /// Each movement with working sets, in order: the warm-up and the ramp sets aren't lifts.
    static func lifts(_ session: SessionPlan, name: (String) -> (name: String, short: String)) -> [Lift] {
        session.blocks.filter { $0.rounds > 0 }.flatMap(\.movements).compactMap { movement in
            let working = movement.working
            guard let first = working.first else { return nil }
            let reps = first.value("reps").map(number) ?? first.value("duration_s").map { number($0) + "s" } ?? ""
            let names = name(movement.exercise)
            return Lift(name: names.name, short: names.short, sets: working.count, reps: reps,
                        load: first.value("load_lb") ?? first.value("load_lb_hand"))
        }
    }

    /// "Squat 225×5": the heaviest set logged, more reps breaking a tie; nil with no loaded sets.
    static func best(_ sets: [LoggedSet], name: (String) -> (name: String, short: String)) -> String? {
        let loaded = sets.compactMap { set -> (set: LoggedSet, load: Double, reps: Double)? in
            guard let load = set.value("load_lb") ?? set.value("load_lb_hand"), load > 0 else { return nil }
            return (set, load, set.value("reps") ?? 0)
        }
        guard let top = loaded.max(by: { ($0.load, $0.reps) < ($1.load, $1.reps) }) else { return nil }
        return "\(name(top.set.exercise).short) \(number(top.load))" + (top.reps > 0 ? "×\(number(top.reps))" : "")
    }

    /// The usual start on `date`'s weekday (TKL-800's rule): the median start over the 8 weeks before it, with at least
    /// 3 sessions, to the nearest quarter hour. In minutes after midnight.
    static func usual(on date: Date, starts: [Date], calendar: Calendar = .current) -> Int? {
        let day = calendar.startOfDay(for: date)
        guard let from = calendar.date(byAdding: .day, value: -56, to: day) else { return nil }
        let weekday = calendar.component(.weekday, from: day)
        let minutes = starts.filter { $0 >= from && $0 < day && calendar.component(.weekday, from: $0) == weekday }
            .map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }.sorted()
        guard minutes.count >= 3 else { return nil }
        let middle = minutes.count / 2
        let median = minutes.count % 2 == 1 ? Double(minutes[middle]) : Double(minutes[middle - 1] + minutes[middle]) / 2
        return Int((median / 15).rounded()) * 15
    }
}
