import Foundation

/// FIT-36: a goal-based program from a start Monday to a target date. Code decides its shape; each week is still
/// planned by TrainingGenerator when the week before ends.
enum ProgramPhase: String, Sendable {
    case base, build, peak
}

struct ProgramWeek: Equatable, Sendable {
    enum Kind: String, Sendable { case base, build, peak, deload, test }

    var phase: ProgramPhase
    var kind: Kind
    /// Away from the usual gym: dumbbells and bodyweight only.
    var travel = false

    /// Deload and test weeks are the light ones.
    var light: Bool { kind == .deload || kind == .test }
}

/// What someone can do now, from onboarding's "Where are you starting?". Only used until there's history.
/// Metrics: `load_lb` + `reps` (best recent set), `reps` (most in a row) or `duration_s` (longest hold).
struct StartingSet: Codable, Hashable, Sendable {
    var exercise: String
    var measurements: [Measurement]

    func value(_ metric: String) -> Double? { measurements.first { $0.metric == metric }?.value }
}

enum ProgramPlan {
    static let travelEquipment: Set<String> = ["dumbbells"]

    /// Weeks from the start Monday through the week holding the target date. At least one.
    static func weekCount(start: Date, target: Date, calendar: Calendar = .current) -> Int {
        max(1, week(of: target, start: start, calendar: calendar) + 1)
    }

    /// Which week of the program a date falls in; negative before the start.
    static func week(of date: Date, start: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: Week.monday(of: start, calendar: calendar),
                                           to: Week.monday(of: date, calendar: calendar)).day ?? 0
        return Int((Double(days) / 7).rounded(.down))
    }

    /// The Monday of week `index`.
    static func monday(_ index: Int, start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7 * index, to: Week.monday(of: start, calendar: calendar))!
    }

    /// Base for the first 35% of weeks, build to 75%, then peak; the last week tests the goals. A deload every
    /// `deloadEvery` weeks (fitness-planner CLAUDE.md "Deload", by age tier), except that the last week of a trip
    /// takes the deload once half that time has passed, so the light week falls while away.
    static func weeks(count: Int, deloadEvery: Int, travel: Set<Int> = []) -> [ProgramWeek] {
        var since = 0
        return (0..<count).map { i in
            let phase: ProgramPhase = i < Int((Double(count) * 0.35).rounded()) ? .base
                : i < Int((Double(count) * 0.75).rounded()) ? .build : .peak
            var week = ProgramWeek(phase: phase, kind: ProgramWeek.Kind(rawValue: phase.rawValue)!, travel: travel.contains(i))
            let tripEnds = travel.contains(i) && !travel.contains(i + 1)
            if i == count - 1 {
                week.kind = .test
            } else if since + 1 >= deloadEvery || (tripEnds && since + 1 >= (deloadEvery + 1) / 2) {
                week.kind = .deload
            }
            since = week.kind == .deload ? 0 : since + 1
            return week
        }
    }

    /// Where a goal should be at the end of week `index`: a straight line from the start to the target over the
    /// weeks that count. Deload and travel weeks hold it flat.
    static func expected(from start: Double, target: Double, at index: Int, weeks: [ProgramWeek]) -> Double {
        let counting = weeks.indices.filter { weeks[$0].kind != .deload && !weeks[$0].travel }
        guard !counting.isEmpty else { return target }
        let done = counting.filter { $0 <= index }.count
        return start + (target - start) * Double(done) / Double(counting.count)
    }

    /// Sets per session the week aims for, within the volume table's range: the low end to build a base, the top
    /// end while building, the middle to peak. Light weeks are cut afterwards like any deload.
    static func sessionSets(_ range: ClosedRange<Int>, phase: ProgramPhase) -> ClosedRange<Int> {
        let sets = switch phase {
        case .base: range.lowerBound
        case .build: range.upperBound
        case .peak: (range.lowerBound + range.upperBound) / 2
        }
        return sets...sets
    }

    /// The working sets a sketched week will hold.
    static func weeklySets(_ week: ProgramWeek, daysPerWeek: Int, sessionMinutes: Int) -> Int {
        let sets = sessionSets(VolumePlan.of(daysPerWeek: daysPerWeek, sessionMinutes: sessionMinutes).setsPerSession,
                               phase: week.phase).lowerBound * daysPerWeek
        return week.light ? Int((Double(sets) * TrainingGenerator.deloadSets).rounded()) : sets
    }

    /// Brzycki (fitness-planner CLAUDE.md "1RM Estimation").
    static func estimatedMax(load: Double, reps: Double) -> Double { load * 36 / (37 - min(reps, 36)) }

    /// A first working set from a starting point, a little under it: 90% of the load Brzycki gives for the
    /// planned reps, 70% of most reps in a row, 75% of the longest hold.
    static func firstTargets(_ start: StartingSet, reps planned: Double) -> (reps: Double?, load: Double?, seconds: Double?) {
        if let seconds = start.value("duration_s") {
            return (nil, nil, max(10, TrainingGenerator.roundTo5(seconds * 0.75)))
        }
        if let load = start.value("load_lb"), let reps = start.value("reps") {
            let best = estimatedMax(load: load, reps: reps)
            return (nil, TrainingGenerator.roundTo5(best * (37 - planned) / 36 * 0.9), nil)
        }
        if let reps = start.value("reps") { return (max(3, (reps * 0.7).rounded()), nil, nil) }
        return (nil, nil, nil)
    }

    /// "Base", "Deload", "Test week"; "· travel" while away.
    static func title(_ week: ProgramWeek) -> String {
        let name = switch week.kind {
        case .test: "Test week"
        default: week.kind.rawValue.capitalized
        }
        return week.travel ? "\(name) · travel" : name
    }

    /// The coach line for a week. A test week names what it tests.
    static func why(_ week: ProgramWeek, tests: [String] = []) -> String {
        if week.travel { return "Dumbbells and bodyweight only." }
        return switch week.kind {
        case .base: "Moderate work, all the reps. Builds capacity for later."
        case .build: "The work gets harder each week."
        case .peak: "Hard and short, so you arrive fresh."
        case .deload: "Same exercises at about half the work."
        case .test: tests.isEmpty ? "See where you are." : "Test: \(tests.joined(separator: ", "))."
        }
    }
}
