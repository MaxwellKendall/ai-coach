import Foundation

/// FIT-273: the plan reveal's promise, "Back Squat 45 → 135 lb by Jan 24": the program's first main lift if every
/// session goes to plan, by the program's own rule (`ReadyProgramWeek`). One rep count adds the step every session; a
/// rep range climbs a rep a session and adds the step once at the top. Deload weeks don't count. The web's quiz works
/// it out the same way (shared/readyPrograms.ts); Tests/Fixtures/ready-program-reveal.json holds both to the same answers.
extension ReadyProgram {
    struct Projection: Equatable, Sendable {
        var exercise: String
        /// The load in lb (a hand, for a dumbbell program): where it starts, then at the end of each week.
        var loads: [Double]
        var perHand: Bool

        var start: Double { loads.first ?? 0 }
        var end: Double { loads.last ?? 0 }
    }

    /// Nil for a body-weight program, which has no load to promise.
    func projection(days count: Int, deloads light: Set<Int>) -> Projection? {
        guard let item = sessions.flatMap(\.exercises).first(where: { $0.main == true && $0.start != nil && $0.reps != nil && $0.exercise != nil }),
              let slug = item.exercise, let start = item.start, let low = item.reps?.min(), let high = item.reps?.max()
        else { return nil }
        let perStep = high - low + 1
        let step = item.step ?? 5
        var loads = [start]
        var counted = 0
        var latest = start
        var session = 0
        for week in 0..<weeks {
            for _ in 0..<count {
                let current = sessions[session % sessions.count]
                session += 1
                guard !light.contains(week), current.exercises.contains(where: { $0.exercise == slug }) else { continue }
                latest = start + step * Double(counted / perStep)
                counted += 1
            }
            loads.append(latest)
        }
        return Projection(exercise: slug, loads: loads, perHand: place == .dumbbells)
    }

    /// The deload weeks of a program started without an age: `ProgramPlan.weeks`' every 7th, as `Profile.program` gives.
    var deloads: Set<Int> {
        let plan = ProgramPlan.weeks(count: weeks, deloadEvery: AgeTier.of(age: 0).deloadEveryWeeks)
        return Set(plan.indices.filter { plan[$0].kind == .deload })
    }
}
