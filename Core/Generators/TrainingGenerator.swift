import Foundation

/// The athlete's training settings, mirroring fitness-planner's config.yaml.
struct TrainingSettings: Sendable {
    var age: Int
    var daysPerWeek: Int
    var sessionMinutes: Int
    /// Days to train, 0 = Monday, in the order the week runs (Sunday first, `Week.ordered`).
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
    /// Where each exercise starts when it has no history yet (FIT-36).
    var starts: [StartingSet] = []
    /// Pounds. What a first load is held to when nothing else is known (FIT-73).
    var bodyWeight: Double? = nil
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
    var primaryMuscles: Set<String>
    var tags: Set<String>
    var substitutes: [String]
    var isGoalLift: Bool
    var isTimed: Bool
    var fatigueCost: Int
    /// One of the author's fitness-planner cards rather than a free-exercise-db entry (FIT-70): the well-known lifts
    /// onboarding lists.
    var isCurated: Bool
    /// free-exercise-db's beginner, intermediate or expert; nil for the author's cards.
    var level: String?
    /// Other names it goes by: free-exercise-db's name for one of the author's cards ("Barbell Deadlift").
    var aliases: [String]

    /// Equipment that is itself the weight: an exercise using any is done with a load, never at body weight.
    static let weights: Set<String> = ["barbell", "dumbbells", "kettlebells", "cable", "machine", "ez_bar", "trap_bar", "medicine_ball", "sled"]
    var isLoaded: Bool { !equipment.isDisjoint(with: Self.weights) }

    init?(slug: String, attributes: [TemplateAttribute]) {
        func values(_ key: String) -> [String] { attributes.first { $0.key == key }?.values ?? [] }
        guard let pattern = values("movement_pattern").first else { return nil }
        let tags = Set(values("tags"))
        self.slug = slug
        self.pattern = pattern
        self.equipment = Set(values("equipment"))
        self.muscles = Set(values("muscles_primary") + values("muscles_secondary"))
        self.primaryMuscles = Set(values("muscles_primary"))
        self.tags = tags
        self.substitutes = values("substitutes")
        self.isGoalLift = tags.contains("goal_lift")
        // Holds and cardio are dosed in seconds.
        self.isTimed = tags.contains("isometric") || tags.contains("timed")
        self.fatigueCost = Int(values("fatigue_cost").first ?? "") ?? 0
        self.isCurated = values("source").isEmpty
        self.level = values("level").first
        self.aliases = values("aliases")
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

    /// FIT-124: the deload rhythm in words, where the program is shown: "At 42, every 5th week is lighter. That's when
    /// the strength from the hard weeks shows up." Without an age, just that it comes.
    static func deloadLine(age: Int?) -> String {
        guard let age else { return "A lighter deload week comes every few weeks." }
        return "At \(age), every \(of(age: age).deloadEveryWeeks)th week is lighter. That’s when the strength from the hard weeks shows up."
    }

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
    /// Superset or circuit grouping from the editor; the generator doesn't make supersets yet.
    var group: Int? = nil
    /// The session's main lift, which PlanGuard lets have 5 sets rather than 4 (FIT-71). Set by whoever proposes the
    /// week; not stored.
    var main = false

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

    /// `asOf` and `rotationStart` are for an extra session mid-week (`session(on:)`): history up to that day,
    /// and a chosen session of the rotation. In a program (FIT-36) its week decides the deload, the volume and
    /// the equipment while travelling.
    static func week(startingOn monday: Date, settings: TrainingSettings, catalog: [Exercise],
                     history: [LoggedSet], weeksSinceDeload: Int, program: ProgramWeek? = nil, asOf: Date? = nil,
                     rotationStart: Int? = nil, calendar: Calendar = .current) -> TrainingWeek {
        var settings = settings
        if program?.travel == true { settings.equipment.formIntersection(ProgramPlan.travelEquipment) }
        let tier = AgeTier.of(age: settings.age)
        let volume = VolumePlan.of(daysPerWeek: settings.daysPerWeek, sessionMinutes: settings.sessionMinutes)
        let deload = program?.light ?? (weeksSinceDeload >= (settings.deloadEveryWeeks ?? tier.deloadEveryWeeks))
        let range = sessionRange(settings, program: program)
        let past = history.filter { $0.date < (asOf ?? monday) }
        let undertrained = undertrainedPatterns(past, before: monday, calendar: calendar)
        let recent = recentExercises(past, sessions: 2, calendar: calendar)
        let allowed = catalog.filter { allows($0, settings) }

        var warnings = weekWarnings(program: program, deload: deload)

        let rotation = volume.split.rotation
        let start = rotationStart ?? Self.rotationStart(rotation, history: past)
        var workouts: [PlannedWorkout] = []
        for (index, day) in settings.trainingDays.prefix(settings.daysPerWeek).enumerated() {
            let session = rotation[(start + index) % rotation.count]
            let date = calendar.date(byAdding: .minute, value: settings.workoutTime,
                                     to: Week.date(day, in: monday, calendar: calendar))!
            workouts += build(session, on: date, prefer: allowed, allowed: allowed, range: range, settings: settings, tier: tier,
                              deload: deload, recent: recent, undertrained: undertrained, history: past, calendar: calendar,
                              warnings: &warnings)
        }
        if range.upperBound < volume.setsPerSession.lowerBound, !deload {
            warnings.append("Sessions held to \(range.upperBound) sets to stay under your \(settings.maxWeeklySets)-set weekly ceiling.")
        }
        return TrainingWeek(workouts: workouts, deload: deload, warnings: warnings)
    }

    /// What kind of week it is, said once at the top.
    static func weekWarnings(program: ProgramWeek?, deload: Bool) -> [String] {
        var warnings: [String] = []
        if program?.kind == .test {
            warnings.append("Test week: light sessions, then see where your goals are.")
        } else if deload {
            warnings.append("Deload week: about half the sets, loads down ~13%, RPE capped at 6.")
        }
        if program?.travel == true { warnings.append("Travel week: dumbbells and bodyweight only.") }
        return warnings
    }

    /// The working sets each session aims for: the volume table's range, a program phase's point in it, and no more
    /// than the weekly ceiling allows each session. The ceiling is the user's own, and PlanGuard holds every week to it
    /// (FIT-71), so the plan fits it rather than only flagging it (config.yaml `max_weekly_volume_sets`).
    static func sessionRange(_ settings: TrainingSettings, program: ProgramWeek?) -> ClosedRange<Int> {
        let volume = VolumePlan.of(daysPerWeek: settings.daysPerWeek, sessionMinutes: settings.sessionMinutes).setsPerSession
        let range = program.map { ProgramPlan.sessionSets(volume, phase: $0.phase) } ?? volume
        let most = settings.maxWeeklySets / max(1, min(settings.daysPerWeek, settings.trainingDays.count))
        return min(range.lowerBound, most)...min(range.upperBound, most)
    }

    /// One session's exercises picked, set and dosed: picks come from `prefer` when it has one for the slot.
    private static func build(_ session: SessionTemplate, on date: Date, prefer: [Exercise], allowed: [Exercise],
                              range: ClosedRange<Int>, settings: TrainingSettings, tier: AgeTier, deload: Bool,
                              recent: Set<String>, undertrained: Set<String>, history: [LoggedSet], calendar: Calendar,
                              warnings: inout [String]) -> [PlannedWorkout] {
        var picks: [(slot: Slot, exercise: Exercise, sets: Int)] = []
        func warn(_ warning: String) { if !warnings.contains(warning) { warnings.append(warning) } }
        for slot in session.slots {
            let used = picks.map(\.exercise.slug)
            guard let exercise = pick(slot, from: prefer, excluding: used, recent: recent)
                    ?? pick(slot, from: allowed, excluding: used, recent: recent) else {
                warn("No allowed \(slot.pattern) exercise for \(session.name).")
                continue
            }
            picks.append((slot, exercise, undertrained.contains(slot.pattern) ? 4 : 3))
        }
        var sets = fit(picks.map { ($0.slot.main, $0.sets) }, to: range)
        // FIT-68: short even with every exercise at its cap. Another exercise for the session's least-worked pattern,
        // never more sets on one lift; the session's own patterns only, so a Push day stays a push day.
        while sets.reduce(0, +) < range.lowerBound {
            let patterns = session.slots.map(\.pattern).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let worked = { (pattern: String) in zip(picks, sets).filter { $0.0.exercise.pattern == pattern }.reduce(0) { $0 + $1.1 } }
            let used = picks.map(\.exercise.slug)
            guard let extra = patterns.sorted(by: { worked($0) < worked($1) }).lazy.compactMap({ pattern in
                let slot = Slot(pattern: pattern, main: false)
                // Only from `prefer`: a rebuilt session would rather be short than bring back what it was asked to avoid.
                return pick(slot, from: prefer, excluding: used, recent: recent).map { (slot, $0) }
            }).first else {
                warn("\(session.name) is \(range.lowerBound - sets.reduce(0, +)) sets short: nothing else in your library fits it.")
                break
            }
            picks.append((extra.0, extra.1, 3))
            sets = fit(picks.map { ($0.slot.main, $0.sets) }, to: range)
        }
        var workouts: [PlannedWorkout] = []
        for (pick, count) in zip(picks, sets) where count > 0 {
            let count = deload ? max(1, Int((Double(count) * deloadSets).rounded())) : count
            let item = workout(pick.exercise, main: pick.slot.main, sets: count, date: date, session: session.name,
                               settings: settings, tier: tier, deload: deload, history: history, calendar: calendar)
            if pick.slot.main, let warmup = warmup(for: item, settings: settings, tier: tier) { workouts.append(warmup) }
            workouts.append(item)
        }
        return workouts
    }

    static func warmup(for item: PlannedWorkout, settings: TrainingSettings, tier: AgeTier) -> PlannedWorkout? {
        guard settings.warmups || tier.mandatoryWarmup, let load = item.target("load_lb") else { return nil }
        return PlannedWorkout(date: item.date, session: item.session, exercise: item.exercise, targets: [
            Measurement(metric: "sets", value: 1, unit: "sets"),
            Measurement(metric: "reps", value: 5, unit: "reps"),
            Measurement(metric: "load_lb", value: max(45, roundTo5(load * 0.6)), unit: "lb"),
        ], note: warmupNote)
    }

    /// FIT-49: today's session rebuilt to order ("leg day", "mix it up", "dumbbells only", "a quick one"): these
    /// slots, filled and dosed by the week's rules from history up to today, preferring exercises not in `avoiding`.
    /// `minutes` shrinks the session's sets in proportion to the usual session length.
    static func session(on date: Date, slots: [Slot], name: String, avoiding: Set<String> = [], minutes: Int? = nil,
                        settings: TrainingSettings, catalog: [Exercise], history: [LoggedSet], weeksSinceDeload: Int,
                        calendar: Calendar = .current) -> [PlannedWorkout] {
        let tier = AgeTier.of(age: settings.age)
        let deload = weeksSinceDeload >= (settings.deloadEveryWeeks ?? tier.deloadEveryWeeks)
        var range = sessionRange(settings, program: nil)
        if let minutes, minutes < settings.sessionMinutes {
            let scale = Double(max(minutes, 10)) / Double(max(settings.sessionMinutes, 1))
            range = max(3, Int(Double(range.lowerBound) * scale)) ... max(3, Int(Double(range.upperBound) * scale))
        }
        let past = history.filter { $0.date < calendar.startOfDay(for: date) }
        let allowed = catalog.filter { allows($0, settings) }
        var warnings: [String] = []
        return build(SessionTemplate(name: name, slots: slots), on: date, prefer: allowed.filter { !avoiding.contains($0.slug) },
                     allowed: allowed, range: range, settings: settings, tier: tier, deload: deload,
                     recent: recentExercises(past, sessions: 2, calendar: calendar),
                     undertrained: undertrainedPatterns(past, before: date, calendar: calendar), history: past,
                     calendar: calendar, warnings: &warnings)
    }

    /// FIT-49: one exercise added or swapped in, dosed like the generator would: from history, else its starting set.
    /// A main lift gets its warm-up.
    static func dose(_ exercise: Exercise, main: Bool, sets: Int, date: Date, session: String, settings: TrainingSettings,
                     history: [LoggedSet], weeksSinceDeload: Int, calendar: Calendar = .current) -> [PlannedWorkout] {
        let tier = AgeTier.of(age: settings.age)
        let deload = weeksSinceDeload >= (settings.deloadEveryWeeks ?? tier.deloadEveryWeeks)
        let item = workout(exercise, main: main, sets: sets, date: date, session: session, settings: settings, tier: tier,
                           deload: deload, history: history.filter { $0.date < calendar.startOfDay(for: date) },
                           calendar: calendar)
        return (main ? warmup(for: item, settings: settings, tier: tier).map { [$0] } ?? [] : []) + [item]
    }

    /// plan.md step 6: equipment on hand, not on the avoid list, and not loading an injured area.
    static func allows(_ exercise: Exercise, _ settings: TrainingSettings) -> Bool {
        exercise.equipment.isSubset(of: settings.equipment)
            && !settings.avoidExercises.contains(exercise.slug)
            && exercise.muscles.isDisjoint(with: settings.injuredAreas)
    }

    /// Main slots take a goal lift (heaviest first); accessories prefer the rest. Both deprioritize
    /// exercises from the last 2 sessions (plan.md step 6), so main lifts only rotate when there's no other goal lift.
    /// The author's cards come before free-exercise-db's hundreds (FIT-70): this is the fallback without the model,
    /// and the catalog's order past the cards is alphabetical, not a choice.
    static func pick(_ slot: Slot, from catalog: [Exercise], excluding used: [String], recent: Set<String>) -> Exercise? {
        let candidates = catalog.enumerated().filter { $0.element.pattern == slot.pattern && !used.contains($0.element.slug) }
        return candidates.min { a, b in
            func key(_ item: (offset: Int, element: Exercise)) -> [Int] {
                let e = item.element
                let curated = e.isCurated ? 0 : 1
                return slot.main
                    ? [curated, e.isGoalLift ? 0 : 1, -e.fatigueCost, recent.contains(e.slug) ? 1 : 0, item.offset]
                    : [curated, recent.contains(e.slug) ? 1 : 0, e.isGoalLift ? 1 : 0, item.offset]
            }
            return key(a).lexicographicallyPrecedes(key(b))
        }?.element
    }

    /// review.md step 3: a pattern with no sets in the last 28 days is undertrained, and plan.md step 5 gives it more sets.
    /// Only while training: after a layoff every pattern is at 0, and adding sets everywhere would be backwards.
    static func undertrainedPatterns(_ history: [LoggedSet], before date: Date, calendar: Calendar = .current) -> Set<String> {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: date)!
        let trained = Training.setsByPattern(history, endingOn: dayBefore, calendar: calendar)
        guard !trained.isEmpty else { return [] }
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

    /// Sets per exercise, at most. General practice: fitness-planner's CLAUDE.md caps sets per session and week
    /// ("Schedule → Volume Mapping"), not per exercise, and filling a session onto one lift gave 12 sets of bench (FIT-68).
    static let maxSets = (main: 5, accessory: 4)
    /// Fewer than this and the exercise is dropped instead: a coach doesn't write one working set.
    static let minSets = 2

    /// Bring a session's sets toward the volume table's range. Under it: main lifts grow first, then accessories,
    /// none past its cap, so the session can stay short (the caller adds exercises). Over it: accessories shrink to
    /// `minSets`, then drop out from the last; then main lifts shrink. 0 means dropped.
    static func fit(_ slots: [(main: Bool, sets: Int)], to range: ClosedRange<Int>) -> [Int] {
        func cap(_ index: Int) -> Int { slots[index].main ? maxSets.main : maxSets.accessory }
        var sets = slots.indices.map { min(slots[$0].sets, cap($0)) }
        guard !sets.isEmpty else { return sets }
        let mains = slots.indices.filter { slots[$0].main }
        let accessories = slots.indices.filter { !slots[$0].main }
        for group in [mains, accessories] {
            var next = 0
            while sets.reduce(0, +) < range.lowerBound, let index = group.indices.lazy
                .map({ group[(next + $0) % group.count] }).first(where: { sets[$0] < cap($0) }) {
                sets[index] += 1
                next = (group.firstIndex(of: index)! + 1) % group.count
            }
        }
        while sets.reduce(0, +) > range.upperBound {
            // Dropping an accessory mustn't take the session under the range while a main lift could give a set.
            let spare = sets.reduce(0, +) - range.lowerBound
            if let index = accessories.filter({ sets[$0] > minSets }).max(by: { sets[$0] < sets[$1] }) {
                sets[index] -= 1
            } else if let index = accessories.last(where: { sets[$0] > 0 && sets[$0] <= spare }) {
                sets[index] = 0
            } else if let index = mains.filter({ sets[$0] > minSets }).max(by: { sets[$0] < sets[$1] }) {
                sets[index] -= 1
            } else if let index = accessories.last(where: { sets[$0] > 0 }) {
                sets[index] = 0
            } else if let index = mains.filter({ sets[$0] > 1 }).max(by: { sets[$0] < sets[$1] }) {
                sets[index] -= 1
            } else {
                break
            }
        }
        return sets
    }

    private static func workout(_ exercise: Exercise, main: Bool, sets: Int, date: Date, session: String,
                                settings: TrainingSettings, tier: AgeTier, deload: Bool,
                                history: [LoggedSet], calendar: Calendar) -> PlannedWorkout {
        let last = lastSession(of: exercise.slug, history, calendar: calendar)
        func lastValue(_ metric: String) -> Double? { last.compactMap { $0.value(metric) }.max() }
        let rpeCap = deload ? deloadRPE : (main ? tier.topRPE : tier.accessoryRPE)
        let reps = main ? settings.style.reps.main : settings.style.reps.accessory
        let first = last.isEmpty ? settings.starts.first { $0.exercise == exercise.slug }
            .map { ProgramPlan.firstTargets($0, reps: reps) } : nil

        var targets = [Measurement(metric: "sets", value: Double(sets), unit: "sets")]
        if exercise.isTimed {
            targets.append(Measurement(metric: "duration_s", value: lastValue("duration_s") ?? first?.seconds ?? 45, unit: "s"))
        } else if exercise.pattern == "carry" {
            targets.append(Measurement(metric: "distance_m", value: lastValue("distance_m") ?? 30, unit: "m"))
        } else {
            targets.append(Measurement(metric: "reps", value: first?.reps ?? reps, unit: "reps"))
        }
        // FIT-69: from the week's start, not the session's day, so a lift has one load across the week (Friday's bench
        // was held at 16 days off while Monday's progressed at 12).
        let weekStart = Week.start(of: date, calendar: calendar)
        let daysOff = last.first.map { max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date), to: weekStart).day ?? 0) }
        if var load = lastValue("load_lb") {
            // FIT-68: last time's top set was at other reps (a style change, main ↔ accessory): the same effort at the
            // planned reps, by Brzycki (fitness-planner CLAUDE.md "1RM Estimation"), keeping the reps left in reserve
            // (10 − RPE, 2 when unlogged) so a submaximal set isn't read as a max. 225×5 at RPE 7 is 200×8.
            if !exercise.isTimed, exercise.pattern != "carry",
               let lastReps = last.filter({ $0.value("load_lb") == load }).compactMap({ $0.value("reps") }).max(),
               lastReps != reps {
                let reserve = 10 - min(max(lastValue("rpe") ?? 8, 6), 10)
                load = roundTo5(load * (37 - min(reps + reserve, 36)) / (37 - min(lastReps + reserve, 36)))
            }
            targets.append(Measurement(metric: "load_lb", value: nextLoad(load, lastRPE: lastValue("rpe"), main: main,
                                                                          tier: tier, deload: deload, daysOff: daysOff),
                                       unit: "lb"))
        } else if let load = lastValue("load_lb_hand") {
            targets.append(Measurement(metric: "load_lb_hand", value: nextLoad(load, lastRPE: nil, main: false, tier: tier,
                                                                               deload: deload, daysOff: daysOff),
                                       unit: "lb/hand"))
        } else if let load = first?.load {
            targets.append(Measurement(metric: "load_lb", value: deload ? roundTo5(load * deloadLoad) : load, unit: "lb"))
        } else if exercise.isLoaded, !exercise.isTimed,
                  let (metric, load) = PlanGuard.firstLoad(exercise, reps: exercise.pattern == "carry" ? nil : reps,
                                                           settings: settings, history: history), load > 0 {
            // A weighted exercise never goes without a weight (FIT-102): one from its movement's anchor lift.
            targets.append(Measurement(metric: metric, value: !deload ? load : metric == "load_lb" ? roundTo5(load * deloadLoad) : (load * deloadLoad / 2.5).rounded(.down) * 2.5,
                                       unit: metric == "load_lb_hand" ? "lb/hand" : "lb"))
        }
        if !exercise.isTimed, exercise.pattern != "carry" {
            targets.append(Measurement(metric: "rpe", value: rpeCap, unit: "RPE"))
        }
        let tempo = main ? tier.tempo.map { "tempo \($0)" } : nil
        return PlannedWorkout(date: date, session: session, exercise: exercise.slug, targets: targets, note: tempo, main: main)
    }

    /// Main lifts add 5 lb when the last session was at least 1 RPE under the tier cap; accessories hold.
    /// (fitness-planner has no written progression rule; this is what its plans did.) Deload drops ~13%.
    /// After time off nothing is added ("missed week means prove it first"), and after 4+ weeks off loads
    /// drop 10% to re-establish (plan.md "returning athlete").
    static func nextLoad(_ load: Double, lastRPE: Double?, main: Bool, tier: AgeTier, deload: Bool,
                         daysOff: Int? = nil) -> Double {
        if deload { return roundTo5(load * deloadLoad) }
        if let daysOff, daysOff > 28 { return roundTo5(load * 0.9) }
        if let daysOff, daysOff > 14 { return load }
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
