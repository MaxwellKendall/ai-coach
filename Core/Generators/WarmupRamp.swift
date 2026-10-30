import Foundation

/// FIT-297: the warm-up shown at the top of Today's session: easy cardio, then a ramp to the first lift's working
/// weight. The empty bar for 10, then about 55%, 75% and 90% of the working weight for 5, 3 and 2, to the nearest
/// 5 lb; a step no heavier than the one before it is left out, so a light lift ramps in fewer steps.
enum WarmupRamp {
    static let bar = 45.0
    static let cardioMinutes = 5

    struct Step: Equatable, Sendable {
        var load: Double
        var reps: Int
    }

    static func steps(to working: Double) -> [Step] {
        guard working > bar else { return [] }
        var steps = [Step(load: bar, reps: 10)]
        for (share, reps) in [(0.55, 5), (0.75, 3), (0.9, 2)] {
            let load = TrainingGenerator.roundTo5(working * share)
            if load > steps.last!.load && load < working { steps.append(Step(load: load, reps: reps)) }
        }
        return steps
    }

    /// About a minute a step, after the cardio.
    static func minutes(to working: Double) -> Int { cardioMinutes + steps(to: working).count }
}
