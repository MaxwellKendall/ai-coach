import Foundation

/// FIT-273: the plan reveal's promise, "Back Squat 45 → 135 lb by Jan 24": the program's first main lift if every
/// session goes to plan, by the program's own rule (`ReadyProgramWeek`). One rep count adds the step every session; a
/// rep range climbs a rep a session and adds the step once at the top. Deload weeks don't count. FIT-281: with a recent
/// set it starts a little under their number and climbs back to it at that pace, then a step a week at most, up to
/// `liftedGain` more by the last week. The web's quiz works it out the same way (shared/readyPrograms.ts);
/// Tests/Fixtures/ready-program-reveal.json holds both to the same answers.
extension StartingSet {
    /// FIT-281: the quiz's "your best recent set": lb (a hand, for a dumbbell program) and reps.
    static func recent(_ exercise: String, weight: Double, reps: Double, perHand: Bool) -> StartingSet {
        StartingSet(exercise: exercise, measurements: [
            Measurement(metric: perHand ? "load_lb_hand" : "load_lb", value: weight, unit: perHand ? "lb/hand" : "lb"),
            Measurement(metric: "reps", value: reps, unit: "reps"),
        ])
    }
}

extension ReadyProgram {
    struct Projection: Equatable, Sendable {
        var exercise: String
        /// The load in lb (a hand, for a dumbbell program): where it starts, then at the end of each week.
        var loads: [Double]
        var perHand: Bool
        /// The headline's first number: their own load for the program's reps when they gave a recent set, else the start.
        var from: Double

        var start: Double { loads.first ?? 0 }
        var end: Double { loads.last ?? 0 }
    }

    /// Someone who has lifted gains this much on their own number over a program, at most and in proportion to the
    /// weeks gone (an intermediate's pace), and never less than one step.
    static let liftedGain = 0.1

    /// The lift the reveal promises and the quiz asks a recent set of: the first main lift with a load.
    var mainLift: Item? {
        sessions.flatMap(\.exercises).first { $0.main == true && $0.start != nil && $0.reps != nil && $0.exercise != nil }
    }

    /// Their load for the item's reps (`ProgramPlan.load(forMax:reps:)`), and where the program starts them: 90% of it,
    /// as `ProgramPlan.firstTargets`, never under the program's own start. Nil when it's no more than that start,
    /// where someone new begins too.
    static func fromRecent(_ item: Item, _ recent: StartingSet) -> (current: Double, start: Double)? {
        guard let start = item.start, let low = item.reps?.min(),
              let load = recent.value("load_lb") ?? recent.value("load_lb_hand"), let reps = recent.value("reps") else { return nil }
        let max = ProgramPlan.estimatedMax(load: load, reps: reps)
        let current = TrainingGenerator.roundTo5(max * (37 - Double(low)) / 36)
        guard current > start else { return nil }
        return (current, Swift.max(start, TrainingGenerator.roundTo5(max * (37 - Double(low)) / 36 * 0.9)))
    }

    /// Nil for a body-weight program, which has no load to promise.
    func projection(days count: Int, deloads light: Set<Int>, recent: StartingSet? = nil) -> Projection? {
        guard let item = mainLift, let slug = item.exercise, let itemStart = item.start,
              let low = item.reps?.min(), let high = item.reps?.max()
        else { return nil }
        let perStep = high - low + 1
        let step = item.step ?? 5
        let own = recent.flatMap { Self.fromRecent(item, $0) }
        let start = own?.start ?? itemStart
        let gain = own.map { Swift.max(step, TrainingGenerator.roundTo5($0.current * Self.liftedGain)) } ?? 0
        var loads = [start]
        var counted = 0
        var latest = start
        var session = 0
        var due = false
        for week in 0..<weeks {
            var stepped = false
            let ceiling = own.map { $0.current + gain * Double(week + 1) / Double(weeks) } ?? .infinity
            for _ in 0..<count {
                let current = sessions[session % sessions.count]
                session += 1
                guard !light.contains(week), current.exercises.contains(where: { $0.exercise == slug }) else { continue }
                if counted > 0, counted % perStep == 0 { due = true }
                let next = latest + step
                if due, own == nil || next <= own!.current {
                    latest = next
                    due = false
                } else if due, !stepped, next <= ceiling {
                    latest = next
                    due = false
                    stepped = true
                }
                counted += 1
            }
            loads.append(latest)
        }
        let from = own.flatMap { latest > $0.current ? $0.current : nil } ?? start
        return Projection(exercise: slug, loads: loads, perHand: place == .dumbbells, from: from)
    }

    /// The quiz's recent set as `Profile.starts` keeps it.
    func recent(in starts: [StartingSet]) -> StartingSet? {
        mainLift.flatMap { lift in starts.first { $0.exercise == lift.exercise } }
    }

    /// The deload weeks of a program started without an age: `ProgramPlan.weeks`' every 7th, as `Profile.program` gives.
    var deloads: Set<Int> {
        let plan = ProgramPlan.weeks(count: weeks, deloadEvery: AgeTier.of(age: 0).deloadEveryWeeks)
        return Set(plan.indices.filter { plan[$0].kind == .deload })
    }
}
