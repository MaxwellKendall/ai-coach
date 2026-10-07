import Foundation

/// FIT-71: the specific rules any proposed week must pass, whoever proposed it: the on-device model (FIT-72) or the
/// fallback TrainingGenerator. Only these rules; everything else about the week is the producer's choice (CLAUDE.md
/// principle 4). Each broken rule is repaired, and the repair listed.
enum PlanGuard {
    enum Rule: String, Sendable {
        /// 1. Equipment on hand, no injured area, nothing avoided; unknown names resolved.
        case exercise
        /// 2. Sets per exercise, and per week.
        case sets, weeklySets
        /// 3. No load past what the history or baseline says can be done.
        case load
        /// 4. Barbell loads in 5 lb steps.
        case plates
        /// 5. Squat and deadlift never both main; no exercise twice in a session.
        case mainLifts, repeats
        /// 6. RPE caps; light weeks at about half the sets.
        case rpe, lightWeek
        /// 7. A full week trains a squat or lunge, a hinge, a push and a pull (FIT-76).
        case movements
    }

    struct Repair: Equatable, Sendable, CustomStringConvertible {
        var rule: Rule
        var text: String
        var description: String { "\(rule.rawValue): \(text)" }
    }

    struct Context {
        /// Equipment as this week has it (a travel week's already narrowed).
        var settings: TrainingSettings
        var catalog: [Exercise]
        var names: [String: String]
        /// Logged sets before the week.
        var history: [LoggedSet]
        /// A deload or test week.
        var light: Bool
        var calendar: Calendar = .current
        /// The rows are a whole week, so rule 7 (every main movement) applies; a single session or part of a week
        /// isn't held to it.
        var wholeWeek = false
    }

    /// Fewer sets than this in a light week's session, as a share of the volume table's top: plan.md step 4 (sets
    /// −40–50%), with room for rounding each exercise's sets.
    static let lightShare = 0.7
    /// The most a load may jump from the last logged top set.
    static let maxJump = 1.1

    static func check(_ workouts: [PlannedWorkout], _ context: Context) -> (workouts: [PlannedWorkout], repairs: [Repair]) {
        var repairs: [Repair] = []
        var sessions: [[PlannedWorkout]] = []
        for row in workouts {
            if let index = sessions.firstIndex(where: { $0[0].date == row.date }) { sessions[index].append(row) }
            else { sessions.append([row]) }
        }
        var result = sessions.flatMap { session(Session(rows: $0, context: context), &repairs) }
        movements(&result, context, &repairs)
        weeklyCeiling(&result, context, &repairs)
        return (result, repairs)
    }

    // MARK: Movements

    /// The movements every full week trains (general practice; fitness-planner's rotations always cover them).
    static let movements: [(name: String, patterns: [String])] = [
        ("a squat or lunge", ["squat", "lunge"]), ("a hinge", ["hinge"]), ("a push", ["push"]), ("a pull", ["pull"]),
    ]

    /// The movements a week leaves out that the user could do: not in a light week, and not one their equipment,
    /// injuries or avoids rule out.
    static func missingMovements(_ workouts: [PlannedWorkout], _ context: Context) -> [(name: String, patterns: [String])] {
        guard context.wholeWeek, !context.light else { return [] }
        let bySlug = Dictionary(context.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let trained = Set(workouts.filter { $0.note != TrainingGenerator.warmupNote }.compactMap { bySlug[$0.exercise]?.pattern })
        return movements.filter { movement in
            trained.isDisjoint(with: movement.patterns)
                && context.catalog.contains { movement.patterns.contains($0.pattern) && TrainingGenerator.allows($0, context.settings) }
        }
    }

    /// 7. A missing movement takes the place of an accessory, the last of the fullest session whose own movement the
    /// week trains elsewhere; the replacement is dosed as TrainingGenerator would, at the accessory's sets.
    private static func movements(_ rows: inout [PlannedWorkout], _ context: Context, _ repairs: inout [Repair]) {
        let bySlug = Dictionary(context.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        for movement in missingMovements(rows, context) {
            let working = rows.indices.filter { rows[$0].note != TrainingGenerator.warmupNote }
            let totals = Dictionary(working.map { (rows[$0].date, Int(rows[$0].target("sets") ?? 0)) }, uniquingKeysWith: +)
            func needed(_ index: Int) -> Bool {
                guard let pattern = bySlug[rows[index].exercise]?.pattern,
                      let group = movements.first(where: { $0.patterns.contains(pattern) }) else { return false }
                return working.filter { bySlug[rows[$0].exercise].map { group.patterns.contains($0.pattern) } ?? false }.count == 1
            }
            guard let index = working.filter({ !rows[$0].main && !needed($0) })
                .max(by: { (totals[rows[$0].date]!, $0) < (totals[rows[$1].date]!, $1) }) else { continue }
            let old = rows[index]
            let used = rows.filter { $0.date == old.date }.map(\.exercise)
            let allowed = context.catalog.filter { TrainingGenerator.allows($0, context.settings) }
            guard let exercise = movement.patterns.lazy.compactMap({
                TrainingGenerator.pick(Slot(pattern: $0, main: false), from: allowed, excluding: used, recent: [])
            }).first else { continue }
            var row = TrainingGenerator.dose(exercise, main: false, sets: Int(old.target("sets") ?? 3), date: old.date,
                                             session: old.session, settings: context.settings, history: context.history,
                                             weeksSinceDeload: 0, calendar: context.calendar).last!
            row.group = old.group
            rows[index] = row
            let name = { (slug: String) in context.names[slug] ?? slug }
            repairs.append(Repair(rule: .movements, text: "\(old.session): the week had no \(movement.name.dropFirst(2)); \(name(exercise.slug)) instead of \(name(old.exercise))."))
        }
    }

    // MARK: One session

    private struct Session {
        var rows: [PlannedWorkout]
        var context: Context
        var bySlug: [String: Exercise]

        init(rows: [PlannedWorkout], context: Context) {
            self.rows = rows
            self.context = context
            bySlug = Dictionary(context.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func session(_ session: Session, _ repairs: inout [Repair]) -> [PlannedWorkout] {
        let context = session.context
        let settings = context.settings
        let tier = AgeTier.of(age: settings.age)
        func name(_ slug: String) -> String { context.names[slug] ?? slug }
        func repair(_ rule: Rule, _ text: String) { repairs.append(Repair(rule: rule, text: "\(session.rows[0].session): \(text)")) }

        let warmups = session.rows.filter { $0.note == TrainingGenerator.warmupNote }
        var rows: [PlannedWorkout] = []
        for var row in session.rows where row.note != TrainingGenerator.warmupNote {
            // 5. No exercise twice.
            if rows.contains(where: { $0.exercise == row.exercise }) {
                repair(.repeats, "\(name(row.exercise)) was in twice; the second is dropped.")
                continue
            }
            // 1. Allowed exercises only.
            let exercise = resolve(row.exercise, in: session.bySlug, names: context.names)
            if exercise == nil || !TrainingGenerator.allows(exercise!, settings) {
                let used = Set(rows.map(\.exercise))
                guard let swap = exercise.map({ nearest($0, session, excluding: used) })
                        ?? search(row.exercise, session, excluding: used) else {
                    repair(.exercise, "\(name(row.exercise)) isn't possible with your equipment or limits, and nothing like it is; dropped.")
                    continue
                }
                let why = exercise == nil ? "isn't in the catalog" : "isn't possible with your equipment or limits"
                repair(.exercise, "\(name(row.exercise)) \(why); \(name(swap.slug)) instead.")
                var dosed = TrainingGenerator.dose(swap, main: row.main, sets: Int(row.target("sets") ?? 3), date: row.date,
                                                   session: row.session, settings: settings, history: context.history,
                                                   weeksSinceDeload: context.light ? .max : 0, calendar: context.calendar).last!
                dosed.group = row.group
                row = dosed
            } else if exercise!.slug != row.exercise {
                row.exercise = exercise!.slug
            }
            rows.append(row)
        }

        // 5. Squat and deadlift never both main (the deadlift card): the deadlift becomes an accessory.
        if rows.contains(where: { $0.main && session.bySlug[$0.exercise]?.pattern == "squat" }) {
            for index in rows.indices where rows[index].main && isDeadlift(rows[index].exercise, session) {
                rows[index].main = false
                repair(.mainLifts, "squat and \(name(rows[index].exercise)) were both main lifts; \(name(rows[index].exercise)) is an accessory.")
            }
        }

        let least = context.light ? 1 : TrainingGenerator.minSets
        for index in rows.indices {
            let row = rows[index]
            let exercise = session.bySlug[row.exercise]
            // 2. Sets per exercise.
            let most = row.main ? TrainingGenerator.maxSets.main : TrainingGenerator.maxSets.accessory
            let sets = Int(row.target("sets") ?? 0)
            if sets > most || sets < least {
                rows[index].set("sets", Double(min(max(sets, least), most)))
                repair(.sets, "\(name(row.exercise)) \(sets) sets → \(min(max(sets, least), most)).")
            }
            // 6. RPE caps (fitness-planner CLAUDE.md "Intensity by tier"; plan.md step 4 for light weeks).
            let cap = context.light ? TrainingGenerator.deloadRPE : row.main ? tier.topRPE : tier.accessoryRPE
            if let rpe = row.target("rpe"), rpe > cap {
                rows[index].set("rpe", cap)
                repair(.rpe, "\(name(row.exercise)) RPE \(Coach.number(rpe)) → \(Coach.number(cap)).")
            }
            // 4. Barbell loads in 5 lb steps.
            let barbell = !(exercise?.equipment ?? []).isDisjoint(with: ["barbell", "trap_bar", "ez_bar"])
            if barbell, let load = row.target("load_lb"), load.truncatingRemainder(dividingBy: 5) != 0 {
                rows[index].set("load_lb", TrainingGenerator.roundTo5(load))
                repair(.plates, "\(name(row.exercise)) \(Coach.number(load)) lb → \(Coach.number(TrainingGenerator.roundTo5(load))) lb.")
            }
            // 3. Load ceilings.
            for metric in ["load_lb", "load_lb_hand"] {
                guard let load = rows[index].target(metric),
                      let ceiling = ceiling(row.exercise, exercise, metric: metric, reps: row.target("reps"), context),
                      load > ceiling.load else { continue }
                let capped = barbell ? (ceiling.load / 5).rounded(.down) * 5 : ceiling.load.rounded(.down)
                rows[index].set(metric, capped)
                repair(.load, "\(name(row.exercise)) \(Coach.number(load)) lb → \(Coach.number(capped)) lb, \(ceiling.why).")
            }
        }

        // 2. A session's sets within the volume table's top for its length (fitness-planner CLAUDE.md "Schedule →
        // Volume Mapping"), so 22 exercises don't land in 30 minutes.
        let sessionMost = TrainingGenerator.sessionRange(settings, program: nil).upperBound
        let sessionTotal = rows.reduce(0) { $0 + Int($1.target("sets") ?? 0) }
        if !context.light, sessionTotal > sessionMost {
            trim(&rows, by: sessionTotal - sessionMost, least: least)
            repair(.sets, "\(sessionTotal) sets in one session → \(rows.reduce(0) { $0 + Int($1.target("sets") ?? 0) }), the most for \(settings.sessionMinutes) minutes.")
        }

        // 6. A light week's session is about half the sets.
        if context.light {
            let most = Int((Double(VolumePlan.of(daysPerWeek: settings.daysPerWeek, sessionMinutes: settings.sessionMinutes)
                .setsPerSession.upperBound) * lightShare).rounded(.down))
            let total = rows.reduce(0) { $0 + Int($1.target("sets") ?? 0) }
            if total > most {
                trim(&rows, by: total - most, least: 1)
                repair(.lightWeek, "\(total) sets in a light week → \(rows.reduce(0) { $0 + Int($1.target("sets") ?? 0) }).")
            }
        }

        // Warm-ups, when the session has them, follow the main lifts: gone with one, and 60% of its load.
        var result: [PlannedWorkout] = []
        for row in rows {
            if row.main, !warmups.isEmpty, let warmup = TrainingGenerator.warmup(for: row, settings: settings, tier: tier) {
                result.append(warmup)
            }
            result.append(row)
        }
        return result
    }

    /// By slug, else by name or another name it goes by ("Barbell Bench Press - Medium Grip"), case aside.
    static func resolve(_ text: String, in bySlug: [String: Exercise], names: [String: String]) -> Exercise? {
        if let exercise = bySlug[text] { return exercise }
        let wanted = text.lowercased().trimmingCharacters(in: .whitespaces)
        return names.first { $0.value.lowercased() == wanted }.flatMap { bySlug[$0.key] } ?? bySlug[Slug.make(text)]
            ?? bySlug.values.first { $0.aliases.contains { $0.lowercased() == wanted } }
    }

    /// A name the catalog doesn't have, searched for by its words, then fewer of them: "Hamstring Curl Deluxe" finds
    /// a hamstring curl.
    private static func search(_ text: String, _ session: Session, excluding used: Set<String>) -> Exercise? {
        search(text, in: session.context.catalog, names: session.context.names, settings: session.context.settings,
               excluding: used, limit: 1).first.flatMap { session.bySlug[$0] }
    }

    /// Slugs for a name the catalog doesn't have: its words, then fewer of them.
    static func search(_ text: String, in catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                       excluding used: Set<String> = [], limit: Int) -> [String] {
        let words = text.split { !$0.isLetter }
        for count in stride(from: words.count, to: 0, by: -1) {
            let found = ExerciseSearch.find(words.prefix(count).joined(separator: " "), in: catalog, names: names,
                                            settings: settings, excluding: used, limit: limit)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// The closest allowed exercise for the same movement: the card's own substitutes first, then the same plane
    /// (vertical or horizontal), then the most primary muscles shared; the author's cards before the rest.
    private static func nearest(_ exercise: Exercise, _ session: Session, excluding used: Set<String>) -> Exercise? {
        let settings = session.context.settings
        let candidates = session.context.catalog.filter {
            $0.pattern == exercise.pattern && $0.slug != exercise.slug && !used.contains($0.slug)
                && TrainingGenerator.allows($0, settings)
        }
        let planes: Set<String> = ["vertical_push", "horizontal_push", "vertical_pull", "horizontal_pull"]
        func key(_ e: Exercise) -> [Int] {
            let substitute = exercise.substitutes.firstIndex(of: e.slug) ?? exercise.substitutes.count
            return [substitute, e.tags.intersection(planes) == exercise.tags.intersection(planes) ? 0 : 1,
                    -e.primaryMuscles.intersection(exercise.primaryMuscles).count, e.isCurated ? 0 : 1,
                    e.tags.contains("isolation") == exercise.tags.contains("isolation") ? 0 : 1]
        }
        return candidates.enumerated().min { a, b in
            (key(a.element) + [a.offset]).lexicographicallyPrecedes(key(b.element) + [b.offset])
        }?.element
    }

    private static func isDeadlift(_ slug: String, _ session: Session) -> Bool {
        session.bySlug[slug]?.pattern == "hinge" && slug.contains("deadlift")
    }

    /// The most `metric` may be for these reps: the rep max the best logged set gives (Brzycki, counting the reps left
    /// in reserve, 10 − RPE or 2 when unlogged, FIT-68) plus one 5 lb step, else the baseline's; and no more than
    /// the last top set + 10%.
    private static func ceiling(_ slug: String, _ exercise: Exercise?, metric: String, reps: Double?, _ context: Context)
        -> (load: Double, why: String)? {
        let sets = context.history.filter { $0.exercise == slug && $0.value(metric) != nil }
        var ceilings: [(load: Double, why: String)] = []
        if let reps {
            let best = sets.compactMap { set -> Double? in
                guard let load = set.value(metric), let done = set.value("reps"), (1...10).contains(done) else { return nil }
                return ProgramPlan.estimatedMax(load: load, reps: done + 10 - min(max(set.value("rpe") ?? 8, 6), 10))
            }.max()
            let baseline = metric == "load_lb" ? context.settings.starts.first { $0.exercise == slug }.flatMap { start in
                start.value("load_lb").flatMap { load in start.value("reps").map { ProgramPlan.estimatedMax(load: load, reps: $0) } }
            } : nil
            if let max = best ?? baseline {
                ceilings.append((max * (37 - min(reps, 36)) / 36 + 5,
                                 "the most your \(best == nil ? "starting point" : "history") gives for \(Int(reps)) reps"))
            }
        }
        if sets.isEmpty, ceilings.isEmpty, let exercise,
           let related = related(exercise, metric: metric, reps: reps, context) {
            ceilings.append(related)
        }
        if let day = sets.map(\.date).max().map(context.calendar.startOfDay),
           let top = sets.filter({ context.calendar.startOfDay(for: $0.date) == day }).max(by: { $0.value(metric)! < $1.value(metric)! }) {
            // At the planned reps: 95×10 last time is 105×8 now, not a jump.
            var load = top.value(metric)!
            if let reps, let done = top.value("reps"), done != reps {
                let reserve = 10 - min(max(top.value("rpe") ?? 8, 6), 10)
                load *= (37 - min(reps + reserve, 36)) / (37 - min(done + reserve, 36))
            }
            ceilings.append((load * maxJump, "10% over your last top set"))
        }
        return ceilings.min { $0.load < $1.load }
    }

    /// FIT-73: the lift each movement is measured against, and the share of its max a first load may be. General
    /// strength-standard ratios (fitness-planner has none): an overhead press is about 65% of a bench, a row about
    /// 80%, a lunge about 60% of a squat; isolation work a third or less.
    static let anchors: [String: (slug: String, share: Double)] = [
        "squat": ("back-squat", 1), "lunge": ("back-squat", 0.6), "legs": ("back-squat", 0.5), "calves": ("back-squat", 0.8),
        "hinge": ("deadlift", 1), "olympic": ("deadlift", 0.6), "carry": ("deadlift", 1),
        "horizontal_push": ("bench-press", 1), "vertical_push": ("bench-press", 0.65), "horizontal_pull": ("bench-press", 0.8),
        "vertical_pull": ("bench-press", 0.8), "arms": ("bench-press", 0.35), "shoulders": ("bench-press", 0.25),
        "core": ("bench-press", 0.25),
    ]
    /// A max from body weight when the anchor lift has none either: about what an untrained adult lifts (general
    /// strength standards, the low end).
    static let bodyWeightShare = ["back-squat": 0.75, "deadlift": 1.0, "bench-press": 0.5]
    /// Each dumbbell or kettlebell, as a share of the barbell load (a dumbbell bench is about 40% of a barbell bench
    /// a hand); a variation of the anchor, as a share of the anchor.
    static let perHandShare = 0.4, variationShare = 0.9

    /// The most an exercise with no history and no starting point may start at: its movement's anchor lift, from the
    /// history, the starting point or body weight, scaled by `anchors`, at two reps in reserve. nil when nothing's known.
    private static func related(_ exercise: Exercise, metric: String, reps: Double?, _ context: Context)
        -> (load: Double, why: String)? {
        let key = exercise.tags.first { $0.hasSuffix("_push") || $0.hasSuffix("_pull") } ?? exercise.pattern
        guard let anchor = anchors[key] else { return nil }
        let best = context.history.filter { $0.exercise == anchor.slug }.compactMap { set -> Double? in
            guard let load = set.value("load_lb"), let done = set.value("reps"), (1...10).contains(done) else { return nil }
            return ProgramPlan.estimatedMax(load: load, reps: done + 10 - min(max(set.value("rpe") ?? 8, 6), 10))
        }.max()
        let start = context.settings.starts.first { $0.exercise == anchor.slug }
        let baseline = start.flatMap { start in
            start.value("load_lb").flatMap { load in start.value("reps").map { ProgramPlan.estimatedMax(load: load, reps: $0) } }
        }
        let body = context.settings.bodyWeight.map { $0 * (bodyWeightShare[anchor.slug] ?? 0.5) }
        guard let max = best ?? baseline ?? body else { return nil }
        let name = context.names[anchor.slug] ?? anchor.slug
        let why = best != nil ? "about what your \(name.lowercased()) history suggests"
            : baseline != nil ? "about what your \(Coach.number(start!.value("load_lb")!))×\(Coach.number(start!.value("reps")!)) \(name.lowercased()) suggests"
            : "about what your body weight suggests for a first week"
        var load = max * anchor.share * (exercise.slug == anchor.slug ? 1 : variationShare)
        if metric == "load_lb_hand" { load *= perHandShare }
        // An estimate, so never a max: two reps left in reserve (RPE 8). Carries are held, not lifted for reps.
        if let reps, exercise.pattern != "carry" { load *= (37 - min(reps + 2, 36)) / 36 }
        return (load, why)
    }

    // MARK: The week

    /// 2. The week's working sets within the user's ceiling.
    private static func weeklyCeiling(_ rows: inout [PlannedWorkout], _ context: Context, _ repairs: inout [Repair]) {
        let working = rows.indices.filter { rows[$0].note != TrainingGenerator.warmupNote }
        let total = working.reduce(0) { $0 + Int(rows[$1].target("sets") ?? 0) }
        guard total > context.settings.maxWeeklySets else { return }
        var items = working.map { rows[$0] }
        trim(&items, by: total - context.settings.maxWeeklySets, least: context.light ? 1 : TrainingGenerator.minSets)
        // Dropped exercises go, with their warm-ups.
        let kept = Set(items.map { "\($0.date.timeIntervalSinceReferenceDate) \($0.exercise)" })
        rows = rows.filter { kept.contains("\($0.date.timeIntervalSinceReferenceDate) \($0.exercise)") }
        rows = rows.map { row in items.first { $0.date == row.date && $0.exercise == row.exercise && row.note != TrainingGenerator.warmupNote } ?? row }
        repairs.append(Repair(rule: .weeklySets, text: "\(total) sets this week → \(items.reduce(0) { $0 + Int($1.target("sets") ?? 0) }), your weekly ceiling."))
    }

    /// Take `excess` sets away, as TrainingGenerator.fit does: accessories a set at a time (the one with the most
    /// first) down to `least`, then whole accessories (the last of the fullest session); then main lifts the same way.
    /// A session keeps one exercise.
    private static func trim(_ rows: inout [PlannedWorkout], by excess: Int, least: Int) {
        var excess = excess
        func sets(_ row: PlannedWorkout) -> Int { Int(row.target("sets") ?? 0) }
        while excess > 0 {
            let counts = Dictionary(rows.map { ($0.date, 1) }, uniquingKeysWith: +)
            let totals = Dictionary(rows.map { ($0.date, sets($0)) }, uniquingKeysWith: +)
            var acted = false
            for main in [false, true] {
                if let index = rows.indices.filter({ rows[$0].main == main && sets(rows[$0]) > least })
                    .max(by: { sets(rows[$0]) < sets(rows[$1]) }) {
                    rows[index].set("sets", Double(sets(rows[index]) - 1))
                    excess -= 1
                } else if let index = rows.indices.filter({ rows[$0].main == main && counts[rows[$0].date]! > 1 })
                    .max(by: { (totals[rows[$0].date]!, $0) < (totals[rows[$1].date]!, $1) }) {
                    excess -= sets(rows[index])
                    rows.remove(at: index)
                } else {
                    continue
                }
                acted = true
                break
            }
            if !acted { return }
        }
    }
}

private extension PlannedWorkout {
    mutating func set(_ metric: String, _ value: Double) {
        if let index = targets.firstIndex(where: { $0.metric == metric }) { targets[index].value = value }
        else { targets.append(Measurement(metric: metric, value: value, unit: ["sets": "sets", "rpe": "RPE", "load_lb": "lb"][metric] ?? metric)) }
    }
}
