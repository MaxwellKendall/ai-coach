import Foundation

/// A change to the plan that was asked for out loud (FIT-29, prototype board 2). The adjuster rules make it;
/// this only says what it does to the day, and nothing is written until Apply.
struct Proposal: Identifiable {
    let id = UUID()
    var said: String
    var title: String
    var lines: [Line]
    var footnote: String
    var keep: String
    var plan: Plan
    var workouts: [PlannedWorkout]

    struct Line: Equatable, Identifiable {
        enum Mark: String { case removed = "−", changed = "~", added = "+", same = "=" }
        var mark: Mark
        var text: String
        var id: String { mark.rawValue + text }
    }

    /// What happens to one day: exercises dropped or swapped in, set counts or targets changed, and the rest
    /// kept as planned. Warm-ups aren't shown. Dropped superset partners read as one line.
    static func lines(before: [PlannedWorkout], after: [PlannedWorkout], names: [String: String]) -> [Line] {
        func name(_ slug: String) -> String { names[slug] ?? slug }
        func working(_ workouts: [PlannedWorkout]) -> [PlannedWorkout] { workouts.filter { $0.note != TrainingGenerator.warmupNote } }
        func sets(_ rows: [PlannedWorkout]) -> Int { rows.reduce(0) { $0 + Int($1.target("sets") ?? 1) } }
        func order(_ rows: [PlannedWorkout]) -> [String] { rows.map(\.exercise).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        let old = working(before), new = working(after)
        var lines: [Line] = []
        var same: [String] = []
        /// Only the effort cap changed: one line for all of them.
        var easier: [String] = []
        func withoutRPE(_ targets: [Measurement]) -> [Measurement] { targets.filter { $0.metric != "rpe" } }
        /// A dropped superset's line, so its partners join it.
        var groupLine: [Int: Int] = [:]
        for exercise in order(old) {
            let was = old.filter { $0.exercise == exercise }, now = new.filter { $0.exercise == exercise }
            if now.isEmpty {
                if let group = was.first?.group, let index = groupLine[group] {
                    lines[index].text += " + " + name(exercise)
                } else {
                    if let group = was.first?.group { groupLine[group] = lines.count }
                    lines.append(Line(mark: .removed, text: name(exercise)))
                }
            } else if sets(was) != sets(now) {
                let count = sets(now)
                lines.append(Line(mark: .changed, text: "\(name(exercise)), \(count) \(count == 1 ? "set" : "sets") instead of \(sets(was))"))
            } else if was.map({ withoutRPE($0.targets) }) != now.map({ withoutRPE($0.targets) }) {
                lines.append(Line(mark: .changed, text: "\(name(exercise)), \(Coach.targets(withoutRPE(now[0].targets))) instead of \(Coach.targets(withoutRPE(was[0].targets)))"))
            } else if was.map(\.targets) != now.map(\.targets) {
                easier.append(name(exercise))
            } else {
                same.append(name(exercise))
            }
        }
        if !easier.isEmpty { lines.append(Line(mark: .changed, text: "\(ListFormatter.localizedString(byJoining: easier)), a little easier")) }
        lines += order(new).filter { !order(old).contains($0) }.map { exercise in
            let dose = new.first { $0.exercise == exercise }.map(Self.dose) ?? ""
            return Line(mark: .added, text: dose.isEmpty ? name(exercise) : "\(name(exercise)), \(dose)")
        }
        if !same.isEmpty { lines.append(Line(mark: .same, text: "\(ListFormatter.localizedString(byJoining: same)) as planned")) }
        return lines
    }

    /// "3 × 5 · 190", "3 × 45 s", "2 × 10".
    static func dose(_ workout: PlannedWorkout) -> String {
        guard let sets = workout.target("sets") else { return "" }
        let each = workout.target("reps").map(Coach.number) ?? workout.target("duration_s").map { "\(Coach.number($0)) s" }
            ?? workout.target("distance_m").map { "\(Coach.number($0)) m" }
        let load = workout.target("load_lb") ?? workout.target("load_lb_hand")
        return [each.map { "\(Coach.number(sets)) × \($0)" } ?? "\(Coach.number(sets)) sets", load.map(Coach.number)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
