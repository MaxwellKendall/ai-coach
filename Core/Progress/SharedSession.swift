import Foundation

/// FIT-113: "Train with me". A planned session as it's shared (the page, infra/lambda/sharePages.ts, reads the same
/// fields), and the same session planned again for a friend with weights from their own history.
enum SharedSession {
    struct Exercise: Codable, Equatable, Sendable {
        /// The catalog slug, so the friend's app plans the same exercise; the page shows `name`.
        var exercise: String
        var name: String
        var sets: Int
        var reps: Int?
        var seconds: Int?
        /// Only when the sharer shows weights.
        var load: Double?
        var unit: String?
    }

    struct Shared: Codable, Equatable, Sendable {
        var title: String
        /// "2026-10-15".
        var date: String
        /// "6:00 AM", when the day has a time.
        var time: String?
        var minutes: Int?
        var exercises: [Exercise]
        var invite: String?
    }

    /// A day's planned workout, one entry per exercise (warm-ups left out), in order.
    static func make(title: String, date: Date, time: String? = nil, workouts: [PlannedWorkout], names: [String: String],
                     showNumbers: Bool, invite: String?, calendar: Calendar = .current) -> Shared {
        var exercises: [Exercise] = []
        for row in workouts where row.note != TrainingGenerator.warmupNote && !row.exercise.isEmpty {
            let sets = Int(row.target("sets") ?? 1)
            let load = row.target("load_lb") ?? row.target("load_lb_hand")
            if let last = exercises.last, last.exercise == row.exercise {
                exercises[exercises.count - 1].sets += sets
                if showNumbers, let load { exercises[exercises.count - 1].load = max(last.load ?? 0, load) }
                continue
            }
            exercises.append(Exercise(
                exercise: row.exercise, name: names[row.exercise] ?? row.exercise, sets: sets,
                reps: row.target("reps").map { Int($0) }, seconds: row.target("duration_s").map { Int($0) },
                load: showNumbers ? load : nil, unit: showNumbers && load != nil ? (row.target("load_lb_hand") != nil ? "lb/hand" : "lb") : nil))
        }
        // About 2.5 minutes a set with rest, and 5 to warm up, to the nearest 5.
        let sets = exercises.map(\.sets).reduce(0, +)
        let minutes = Int((Double(sets) * 2.5 + 5) / 5) * 5
        return Shared(title: title, date: day(date, calendar: calendar), time: time, minutes: sets > 0 ? minutes : nil,
                      exercises: exercises, invite: invite)
    }

    /// The session for the friend on its day: the same exercises, sets and reps; each lift's weight from their own
    /// best estimated max (90% of what Brzycki gives for the reps, like a first week), or left for them to fill in.
    static func workouts(_ shared: Shared, history: [LoggedSet], calendar: Calendar = .current) -> [PlannedWorkout] {
        guard let date = date(shared.date, calendar: calendar) else { return [] }
        return shared.exercises.map { exercise in
            var targets = [Measurement(metric: "sets", value: Double(exercise.sets), unit: "sets")]
            if let reps = exercise.reps { targets.append(Measurement(metric: "reps", value: Double(reps), unit: "reps")) }
            if let seconds = exercise.seconds { targets.append(Measurement(metric: "duration_s", value: Double(seconds), unit: "s")) }
            if let reps = exercise.reps, let max = bestMax(exercise.exercise, in: history) {
                let load = TrainingGenerator.roundTo5(ProgramPlan.load(forMax: max, reps: Double(reps)) * 0.9)
                if load > 0 { targets.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
            }
            return PlannedWorkout(date: date, session: shared.title, exercise: exercise.exercise, targets: targets,
                                  adjustedReason: "shared")
        }
    }

    static func bestMax(_ exercise: String, in history: [LoggedSet]) -> Double? {
        history.filter { $0.exercise == exercise }.compactMap { set -> Double? in
            guard let load = set.value("load_lb"), let reps = set.value("reps"), load > 0, reps > 0 else { return nil }
            return ProgramPlan.estimatedMax(load: load, reps: reps)
        }.max()
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
