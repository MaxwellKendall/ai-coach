import Foundation

/// The athlete's training settings, mirroring fitness-planner's config.yaml.
struct TrainingSettings: Sendable {
    var age: Int
    var daysPerWeek: Int
    var sessionMinutes: Int
    /// Days to train, 0 = Monday.
    var trainingDays: [Int]
    /// Minutes after midnight.
    var workoutTime: Int
    var equipment: Set<String>
    var injuredAreas: Set<String> = []
    var avoidExercises: Set<String> = []
    var maxWeeklySets: Int
    var style: TrainingStyle = .powerbuilding
    var warmups = true
    /// nil uses the age tier's default.
    var deloadEveryWeeks: Int?
}

enum TrainingStyle: String, Codable, CaseIterable, Sendable {
    case powerlifting, hypertrophy, powerbuilding, functional

    /// plan.md step 7 only defines powerbuilding (3–6 compound, 8–15 accessory); the others are general practice.
    var reps: (main: Double, accessory: Double) {
        switch self {
        case .powerlifting: (3, 8)
        case .powerbuilding: (5, 10)
        case .functional: (6, 12)
        case .hypertrophy: (8, 12)
        }
    }
}

/// An exercise as the generator sees it, read from a catalog template's attributes.
struct Exercise: Sendable {
    var slug: String
    var pattern: String
    var equipment: Set<String>
    var muscles: Set<String>
    var substitutes: [String]
    var isGoalLift: Bool
    var isTimed: Bool
    var fatigueCost: Int

    init?(slug: String, attributes: [TemplateAttribute]) {
        func values(_ key: String) -> [String] { attributes.first { $0.key == key }?.values ?? [] }
        guard let pattern = values("movement_pattern").first else { return nil }
        let tags = Set(values("tags"))
        self.slug = slug
        self.pattern = pattern
        self.equipment = Set(values("equipment"))
        self.muscles = Set(values("muscles_primary") + values("muscles_secondary"))
        self.substitutes = values("substitutes")
        self.isGoalLift = tags.contains("goal_lift")
        self.isTimed = tags.contains("isometric")
        self.fatigueCost = Int(values("fatigue_cost").first ?? "") ?? 0
    }
}

/// CLAUDE.md "Age-Bracket Goal Tiers" and "Intensity by tier". Ranges use their upper (cap) or more
/// conservative end, per "At tier boundaries, default to the more conservative tier".
struct AgeTier: Equatable, Sendable {
    var name: String
    var topRPE: Double
    var accessoryRPE: Double
    var mandatoryWarmup: Bool
    var tempo: String?
    var deloadEveryWeeks: Int

    static func of(age: Int) -> AgeTier {
        switch age {
        case ..<30: AgeTier(name: "18–29", topRPE: 9, accessoryRPE: 8, mandatoryWarmup: false, tempo: nil, deloadEveryWeeks: 7)
        case 30..<40: AgeTier(name: "30–39", topRPE: 8, accessoryRPE: 7, mandatoryWarmup: false, tempo: nil, deloadEveryWeeks: 6)
        case 40..<50: AgeTier(name: "40–49", topRPE: 7, accessoryRPE: 7, mandatoryWarmup: true, tempo: nil, deloadEveryWeeks: 5)
        case 50..<60: AgeTier(name: "50–59", topRPE: 7, accessoryRPE: 6, mandatoryWarmup: true, tempo: "3-1-1-1", deloadEveryWeeks: 4)
        default: AgeTier(name: "60+", topRPE: 6, accessoryRPE: 6, mandatoryWarmup: true, tempo: "slow", deloadEveryWeeks: 4)
        }
    }
}

/// One slot in a session template: a movement pattern, either the session's main lift or an accessory.
struct Slot: Equatable, Sendable {
    var pattern: String
    var main: Bool
}

struct SessionTemplate: Equatable, Sendable {
    var name: String
    var slots: [Slot]
}

enum Split: String, Sendable {
    case fullBody, upperLower, pushPullLegs

    /// The rotation. Squat and deadlift are never both main lifts in one session (deadlift card).
    var rotation: [SessionTemplate] {
        func s(_ name: String, _ slots: [(String, Bool)]) -> SessionTemplate {
            SessionTemplate(name: name, slots: slots.map { Slot(pattern: $0.0, main: $0.1) })
        }
        let upper = s("Upper", [("push", true), ("pull", true), ("push", false), ("pull", false), ("core", false)])
        switch self {
        case .fullBody:
            // The A/B sessions fitness-planner's real plans use.
            return [s("Session A", [("squat", true), ("pull", true), ("pull", false), ("carry", false), ("core", false)]),
                    s("Session B", [("push", true), ("hinge", true), ("pull", false), ("push", false), ("core", false)])]
        case .upperLower:
            return [upper, s("Lower A", [("squat", true), ("hinge", false), ("carry", false), ("core", false)]),
                    upper, s("Lower B", [("hinge", true), ("squat", false), ("carry", false), ("core", false)])]
        case .pushPullLegs:
            return [s("Push", [("push", true), ("push", false), ("core", false)]),
                    s("Pull", [("pull", true), ("pull", false), ("carry", false)]),
                    s("Legs", [("squat", true), ("hinge", false), ("core", false)]),
                    upper,
                    s("Lower", [("hinge", true), ("squat", false), ("carry", false), ("core", false)])]
        }
    }
}

/// CLAUDE.md "Schedule → Volume Mapping".
struct VolumePlan: Equatable, Sendable {
    var split: Split
    var setsPerSession: ClosedRange<Int>

    static func of(daysPerWeek days: Int, sessionMinutes minutes: Int) -> VolumePlan {
        let long = minutes >= 60
        switch days {
        case ...2: return VolumePlan(split: .fullBody, setsPerSession: long ? 20...24 : 14...18)
        case 3: return VolumePlan(split: .fullBody, setsPerSession: long ? 18...22 : 14...18)
        case 4: return VolumePlan(split: .upperLower, setsPerSession: long ? 18...22 : 14...18)
        default: return VolumePlan(split: .pushPullLegs, setsPerSession: 16...22)
        }
    }
}

/// One exercise on one day. FIT-5 turns these into PlannedActivity rows.
struct PlannedWorkout: Equatable, Sendable {
    var date: Date
    var session: String
    var exercise: String
    var targets: [Measurement]
    var note: String?
    var adjustedReason: String?

    func target(_ metric: String) -> Double? { targets.first { $0.metric == metric }?.value }
}

struct TrainingWeek: Equatable, Sendable {
    var workouts: [PlannedWorkout]
    var deload: Bool
    var warnings: [String]

    /// Working sets, excluding warm-ups.
    var totalSets: Int {
        workouts.filter { $0.note != TrainingGenerator.warmupNote }.reduce(0) { $0 + Int($1.target("sets") ?? 0) }
    }
}

/// Deterministic weekly training plan, ported from fitness-planner's /plan (plan.md steps 2–7).
enum TrainingGenerator {
    static let warmupNote = "warm-up"
    /// plan.md step 4: sets −40–50%, loads −10–15%, RPE cap 6.
    static let deloadSets = 0.55, deloadLoad = 0.87, deloadRPE = 6.0

    static func week(startingOn monday: Date, settings: TrainingSettings, catalog: [Exercise],
                     history: [LoggedSet], weeksSinceDeload: Int, calendar: Calendar = .current) -> TrainingWeek {
        let tier = AgeTier.of(age: settings.age)
        let volume = VolumePlan.of(daysPerWeek: settings.daysPerWeek, sessionMinutes: settings.sessionMinutes)
        let deload = weeksSinceDeload >= (settings.deloadEveryWeeks ?? tier.deloadEveryWeeks)
        let past = history.filter { $0.date < monday }
        let undertrained = undertrainedPatterns(past, before: monday, calendar: calendar)
        let recent = recentExercises(past, sessions: 2, calendar: calendar)
        let allowed = catalog.filter { allows($0, settings) }

        var warnings: [String] = []
        if deload { warnings.append("Deload week: about half the sets, loads down ~13%, RPE capped at 6.") }

        let rotation = volume.split.rotation
        let start = rotationStart(rotation, history: past)
        var workouts: [PlannedWorkout] = []
        for (index, day) in settings.trainingDays.prefix(settings.daysPerWeek).enumerated() {
            let session = rotation[(start + index) % rotation.count]
            let date = calendar.date(byAdding: .minute, value: settings.workoutTime,
                                     to: calendar.date(byAdding: .day, value: day, to: monday)!)!
            var picks: [(slot: Slot, exercise: Exercise, sets: Int)] = []
            for slot in session.slots {
                guard let exercise = pick(slot, from: allowed, excluding: picks.map(\.exercise.slug), recent: recent) else {
                    warnings.append("No allowed \(slot.pattern) exercise for \(session.name).")
                    continue
                }
                picks.append((slot, exercise, undertrained.contains(slot.pattern) ? 4 : 3))
            }
            let sets = fit(picks.map { ($0.slot.main, $0.sets) }, to: volume.setsPerSession)
            for (pick, count) in zip(picks, sets) {
                let count = deload ? max(1, Int((Double(count) * deloadSets).rounded())) : count
                let item = workout(pick.exercise, main: pick.slot.main, sets: count, date: date, session: session.name,
                                   settings: settings, tier: tier, deload: deload, history: past, calendar: calendar)
                if pick.slot.main, settings.warmups || tier.mandatoryWarmup, let load = item.target("load_lb") {
                    workouts.append(PlannedWorkout(date: date, session: session.name, exercise: pick.exercise.slug, targets: [
                        Measurement(metric: "sets", value: 1, unit: "sets"),
                        Measurement(metric: "reps", value: 5, unit: "reps"),
                        Measurement(metric: "load_lb", value: max(45, roundTo5(load * 0.6)), unit: "lb"),
                    ], note: warmupNote))
                }
                workouts.append(item)
            }
        }
        let week = TrainingWeek(workouts: workouts, deload: deload, warnings: warnings)
        if week.totalSets > settings.maxWeeklySets {
            return TrainingWeek(workouts: workouts, deload: deload, warnings: warnings
                + ["\(week.totalSets) planned sets is over your \(settings.maxWeeklySets)-set weekly ceiling."])
        }
        return week
    }

    /// plan.md step 6: equipment on hand, not on the avoid list, and not loading an injured area.
    static func allows(_ exercise: Exercise, _ settings: TrainingSettings) -> Bool {
        exercise.equipment.isSubset(of: settings.equipment)
            && !settings.avoidExercises.contains(exercise.slug)
            && exercise.muscles.isDisjoint(with: settings.injuredAreas)
    }

    /// Main slots take a goal lift (heaviest first); accessories prefer the rest. Both deprioritize
    /// exercises from the last 2 sessions (plan.md step 6), so main lifts only rotate when there's no other goal lift.
    static func pick(_ slot: Slot, from catalog: [Exercise], excluding used: [String], recent: Set<String>) -> Exercise? {
        let candidates = catalog.enumerated().filter { $0.element.pattern == slot.pattern && !used.contains($0.element.slug) }
        return candidates.min { a, b in
            func key(_ item: (offset: Int, element: Exercise)) -> [Int] {
                let e = item.element
                return slot.main
                    ? [e.isGoalLift ? 0 : 1, -e.fatigueCost, recent.contains(e.slug) ? 1 : 0, item.offset]
                    : [recent.contains(e.slug) ? 1 : 0, e.isGoalLift ? 1 : 0, item.offset]
            }
            return key(a).lexicographicallyPrecedes(key(b))
        }?.element
    }

    /// review.md step 3: a pattern with no sets in the last 28 days is undertrained, and plan.md step 5 gives it more sets.
    static func undertrainedPatterns(_ history: [LoggedSet], before date: Date, calendar: Calendar = .current) -> Set<String> {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: date)!
        let trained = Training.setsByPattern(history, endingOn: dayBefore, calendar: calendar)
        return Set(["squat", "hinge", "push", "pull", "carry", "core"].filter { (trained[$0] ?? 0) == 0 })
    }

    /// Exercises done in the last `sessions` training days.
    static func recentExercises(_ history: [LoggedSet], sessions: Int, calendar: Calendar = .current) -> Set<String> {
        let days = Set(history.map { calendar.startOfDay(for: $0.date) }).sorted().suffix(sessions)
        return Set(history.filter { days.contains(calendar.startOfDay(for: $0.date)) }.map(\.exercise))
    }

    /// Continue the rotation: start with the session whose main lifts were trained longest ago.
    static func rotationStart(_ rotation: [SessionTemplate], history: [LoggedSet]) -> Int {
        let last = Dictionary(history.compactMap { set in set.pattern.map { ($0, set.date) } }, uniquingKeysWith: max)
        let staleness = rotation.map { session in
            session.slots.filter(\.main).compactMap { last[$0.pattern] }.max() ?? .distantPast
        }
        return staleness.indices.min { staleness[$0] < staleness[$1] } ?? 0
    }

    /// Bring a session's sets into the volume table's range: add to main lifts first, trim accessories first.
    static func fit(_ slots: [(main: Bool, sets: Int)], to range: ClosedRange<Int>) -> [Int] {
        var sets = slots.map(\.sets)
        guard !sets.isEmpty else { return sets }
        let mains = slots.indices.filter { slots[$0].main }
        let growable = mains.isEmpty ? Array(slots.indices) : mains
        var next = 0
        while sets.reduce(0, +) < range.lowerBound {
            sets[growable[next % growable.count]] += 1
            next += 1
        }
        while sets.reduce(0, +) > range.upperBound {
            let accessories = slots.indices.filter { !slots[$0].main && sets[$0] > 1 }
            guard let index = (accessories.isEmpty ? slots.indices.filter { sets[$0] > 1 } : accessories)
                .max(by: { sets[$0] < sets[$1] }) else { break }
            sets[index] -= 1
        }
        return sets
    }

    private static func workout(_ exercise: Exercise, main: Bool, sets: Int, date: Date, session: String,
                                settings: TrainingSettings, tier: AgeTier, deload: Bool,
                                history: [LoggedSet], calendar: Calendar) -> PlannedWorkout {
        let last = lastSession(of: exercise.slug, history, calendar: calendar)
        func lastValue(_ metric: String) -> Double? { last.compactMap { $0.value(metric) }.max() }
        let rpeCap = deload ? deloadRPE : (main ? tier.topRPE : tier.accessoryRPE)

        var targets = [Measurement(metric: "sets", value: Double(sets), unit: "sets")]
        if exercise.isTimed {
            targets.append(Measurement(metric: "duration_s", value: lastValue("duration_s") ?? 45, unit: "s"))
        } else if exercise.pattern == "carry" {
            targets.append(Measurement(metric: "distance_m", value: lastValue("distance_m") ?? 30, unit: "m"))
        } else {
            targets.append(Measurement(metric: "reps", value: main ? settings.style.reps.main : settings.style.reps.accessory,
                                       unit: "reps"))
        }
        if let load = lastValue("load_lb") {
            targets.append(Measurement(metric: "load_lb", value: nextLoad(load, lastRPE: lastValue("rpe"), main: main,
                                                                          tier: tier, deload: deload), unit: "lb"))
        } else if let load = lastValue("load_lb_hand") {
            targets.append(Measurement(metric: "load_lb_hand", value: deload ? roundTo5(load * deloadLoad) : load,
                                       unit: "lb/hand"))
        }
        if !exercise.isTimed, exercise.pattern != "carry" {
            targets.append(Measurement(metric: "rpe", value: rpeCap, unit: "RPE"))
        }
        let tempo = main ? tier.tempo.map { "tempo \($0)" } : nil
        return PlannedWorkout(date: date, session: session, exercise: exercise.slug, targets: targets, note: tempo)
    }

    /// Main lifts add 5 lb when the last session was at least 1 RPE under the tier cap; accessories hold.
    /// (fitness-planner has no written progression rule; this is what its plans did.) Deload drops ~13%.
    static func nextLoad(_ load: Double, lastRPE: Double?, main: Bool, tier: AgeTier, deload: Bool) -> Double {
        if deload { return roundTo5(load * deloadLoad) }
        guard main, let rpe = lastRPE, rpe <= tier.topRPE - 1 else { return load }
        return load + 5
    }

    static func roundTo5(_ value: Double) -> Double { (value / 5).rounded() * 5 }

    private static func lastSession(of slug: String, _ history: [LoggedSet], calendar: Calendar) -> [LoggedSet] {
        let sets = history.filter { $0.exercise == slug }
        guard let day = sets.map(\.date).max().map(calendar.startOfDay) else { return [] }
        return sets.filter { calendar.startOfDay(for: $0.date) == day }
    }
}
