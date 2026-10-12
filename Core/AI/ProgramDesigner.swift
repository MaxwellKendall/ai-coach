import Foundation
import FoundationModels
import Synchronization

/// FIT-72: the on-device model designs each week (FIT-67, CLAUDE.md principle 4): the split, the sessions, their
/// exercises from the catalog under the user's equipment (it searches with find_exercises), order, supersets, sets,
/// reps, loads and RPE. Code then only resolves names, adds the warm-ups and tempo fitness-planner's age tiers call
/// for, and runs PlanGuard. Without Apple Intelligence, or when generation fails, TrainingGenerator plans the week.
enum ProgramDesigner {
    struct Request: Sendable {
        var monday: Date
        var settings: TrainingSettings
        var catalog: [Exercise]
        var names: [String: String]
        /// Logged sets, of any date; only those before `monday` are used.
        var history: [LoggedSet]
        var weeksSinceDeload: Int
        var program: ProgramWeek?
        /// "week 5 of 12", when in a program.
        var programIndex: Int?
        var programWeeks: Int?
        /// "Bench Press 225 lb by Dec 1".
        var goals: [String] = []
        /// What was planned the week before, for the progression.
        var lastWeek: [PlannedWorkout] = []
        /// FIT-77: a version of this week to differ from ("Try another"): its sessions are shown, and the model asked
        /// for different exercises.
        var differentFrom: [PlannedWorkout] = []
        /// FIT-95: this week's phase in the program brief, the goals it works toward, and the program's weeks for
        /// where each goal should be by the end of this one.
        var brief: ProgramBrief.Phase?
        var goalLifts: [GoalLift] = []
        var programPlan: [ProgramWeek] = []
        /// FIT-96: hours slept a night over the week before, on average, when logged.
        var sleepHours: Double?
        /// FIT-100: main lifts' top sets, decided before the week from how they went.
        var progression: [Progression.Decision] = []
        var calendar: Calendar = .current
    }

    enum Source: String, Sendable { case model, fallback }

    struct Result: Sendable {
        var week: TrainingWeek
        var repairs: [PlanGuard.Repair]
        var source: Source
        /// Why the fallback planned it.
        var fallbackReason: String?
        var seconds: Double
        /// The model's find_exercises searches and renames, for the evals.
        var calls: [String] = []
        /// The model's aim for each session: "Upper: heavier bench triples toward 225".
        var why: [String] = []
    }

    // MARK: What the model writes

    @Generable
    struct DesignedWeek {
        @Guide(description: "One session per training day, in order", .minimumCount(1), .maximumCount(7))
        var sessions: [Session]

        @Generable
        struct Session {
            @Guide(description: "Like Upper, Lower or Full Body A")
            var name: String
            @Guide(description: "Its aim, in a few words")
            var why: String
            @Guide(description: "Main lifts first", .minimumCount(3), .maximumCount(7))
            var exercises: [Item]
        }

        @Generable
        struct Item {
            @Guide(description: "Exactly as listed")
            var name: String
            @Guide(description: "One or two main lifts a session")
            var main: Bool
            @Guide(.range(2...5))
            var sets: Int
            @Guide(.range(1...30))
            var reps: Int?
            @Guide(description: "Holds and cardio")
            var seconds: Int?
            @Guide(description: "Carries")
            var meters: Int?
            @Guide(description: "Bar total, or each dumbbell")
            var pounds: Int?
            @Guide(.range(5...10))
            var rpe: Int?
            @Guide(description: "Same number, same superset")
            var superset: Int?
        }
    }

    @Generable
    struct FirstLoads {
        var loads: [Load]

        @Generable
        struct Load {
            @Guide(description: "The exercise, as written")
            var name: String
            @Guide(description: "Bar total, or each dumbbell or kettlebell", .range(5...600))
            var pounds: Int
        }
    }

    @Generable
    struct Renames {
        var exercises: [Rename]

        @Generable
        struct Rename {
            @Guide(description: "The name as it was")
            var from: String
            @Guide(description: "One of its options, written exactly")
            var to: String
        }
    }

    // MARK: The week

    static func week(_ request: Request, model: any AIModel = OnDeviceModel()) async -> Result {
        let clock = ContinuousClock.now
        var settings = request.settings
        if request.program?.travel == true { settings.equipment.formIntersection(ProgramPlan.travelEquipment) }
        let tier = AgeTier.of(age: settings.age)
        let light = request.program?.light ?? (request.weeksSinceDeload >= (settings.deloadEveryWeeks ?? tier.deloadEveryWeeks))
        let past = request.history.filter { $0.date < request.monday }
        let context = PlanGuard.Context(settings: settings, catalog: request.catalog, names: request.names, history: past,
                                        light: light, calendar: request.calendar, wholeWeek: true, decided: request.progression)
        func seconds() -> Double {
            let elapsed = ContinuousClock.now - clock
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        func fallback(_ reason: String, calls: [String] = []) -> Result {
            let week = TrainingGenerator.week(startingOn: request.monday, settings: request.settings, catalog: request.catalog,
                                              history: request.history, weeksSinceDeload: request.weeksSinceDeload,
                                              program: request.program, calendar: request.calendar)
            let guarded = PlanGuard.check(week.workouts, context)
            return Result(week: TrainingWeek(workouts: guarded.workouts, deload: week.deload, warnings: week.warnings),
                          repairs: guarded.repairs, source: .fallback, fallbackReason: reason, seconds: seconds(), calls: calls)
        }
        guard model.isAvailable else { return fallback("the model isn't available") }

        let log = Log()
        do {
            var designed = try await design(request, settings: settings, tier: tier, light: light, log: log, model: model)
            // FIT-76: a week short of sessions, or leaving out a main movement, goes back once, saying what's missing.
            let days = settings.trainingDays.prefix(settings.daysPerWeek).count
            let missing = PlanGuard.missingMovements(rows(designed, request, settings: settings, tier: tier).workouts, context)
            if designed.sessions.count < days || !missing.isEmpty {
                var problems: [String] = []
                if designed.sessions.count < days { problems.append("only \(designed.sessions.count) sessions for \(days) days") }
                if !missing.isEmpty { problems.append("no " + missing.map { String($0.name.dropFirst(2)) }.joined(separator: " and no ")) }
                log.calls.withLock { $0.append("again: \(problems.joined(separator: ", "))") }
                designed = try await design(request, settings: settings, tier: tier, light: light, log: log, model: model, note: """
                    A first try had \(problems.joined(separator: " and ")). Design \(days) different sessions that \
                    together train a squat or lunge, a hinge, a push and a pull.
                    """)
            }
            try await rename(&designed, request, settings: settings, log: log, model: model)
            try await fillLoads(&designed, request, settings: settings, log: log, model: model)
            let (workouts, why) = rows(designed, request, settings: settings, tier: tier)
            guard !workouts.isEmpty else { return fallback("the model planned nothing", calls: log.calls.withLock { $0 }) }
            let guarded = PlanGuard.check(workouts, context)
            return Result(week: TrainingWeek(workouts: guarded.workouts, deload: light,
                                             warnings: TrainingGenerator.weekWarnings(program: request.program, deload: light)),
                          repairs: guarded.repairs, source: .model, seconds: seconds(), calls: log.calls.withLock { $0 },
                          why: why)
        } catch {
            return fallback("\(error)", calls: log.calls.withLock { $0 })
        }
    }

    /// The on-device model now and then fails a generation it gets right the next time (FIT-49 saw the same with tool
    /// calls); one more try, from the start. A week that ran out of context (searches fill it) tries again from the
    /// menu alone.
    private static func design(_ request: Request, settings: TrainingSettings, tier: AgeTier, light: Bool, log: Log,
                               model: any AIModel, note: String? = nil) async throws -> DesignedWeek {
        var tries = 0, tools = true
        while true {
            tries += 1
            do {
                let session = model.session(tools: tools ? [FindExercises(request: request, settings: settings, log: log)] : [],
                                            instructions: instructions(settings, tier: tier, light: light))
                return try await session.respond(to: prompt(request, settings: settings, light: light) + (note.map { "\n" + $0 } ?? ""),
                                                 generating: DesignedWeek.self)
            } catch {
                if error is CancellationError || AIFailure(error) == .guardrail { throw error }
                if AIFailure(error) == .tooLong { tools = false }
                if tries == 2 { throw error }
                log.calls.withLock { $0.append("retry after \(error)") }
            }
        }
    }

    // MARK: Prompt

    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func instructions(_ settings: TrainingSettings, tier: AgeTier, light: Bool) -> String {
        let rpe = light ? "RPE at most \(Coach.number(TrainingGenerator.deloadRPE))"
            : "RPE at most \(Coach.number(tier.topRPE)) for main lifts and \(Coach.number(tier.accessoryRPE)) for the rest"
        return """
            You are a strength coach designing one week of training for one person. You choose the split, each \
            session's exercises and their order, supersets, sets, reps, loads and effort, to move them toward their goals.
            Each session has 4 to 6 exercises, main lifts first; across the week, train a squat or lunge, a hinge, a \
            push and a pull. Choose exercises from the menu below, or call find_exercises for more. Use only names \
            they give, written exactly.
            Give pounds for each weighted exercise from their recent sets and starting points; none for bodyweight ones. \
            With neither, pick a light first load from a related lift: each dumbbell for a dumbbell bench is about 40% \
            of the barbell bench, an overhead press about 65% of it, a row about 80%, a lunge about 60% of the squat. \
            Reps for lifts, seconds for holds and cardio, meters for carries; RPE for lifts only.
            Each week builds on the last: add a little load or a rep where the last top set was easy, hold where it was hard.
            The plan is checked against these rules, so keep to them: at most \(TrainingGenerator.maxSets.main) sets for a \
            main lift and \(TrainingGenerator.maxSets.accessory) for the rest, at least \(light ? 1 : TrainingGenerator.minSets); \
            at most \(settings.maxWeeklySets) working sets in the week; \(rpe); squat and deadlift never both main lifts \
            in one session; no exercise twice in a session; no load past what their recent sets show they can do.
            """
    }

    static func prompt(_ request: Request, settings: TrainingSettings, light: Bool) -> String {
        let days = Array(settings.trainingDays.prefix(settings.daysPerWeek))
        let range = TrainingGenerator.sessionRange(settings, program: request.program)
        var lines: [String] = []
        if let program = request.program {
            let position = request.programIndex.map { index in "Week \(index + 1)\(request.programWeeks.map { " of \($0)" } ?? ""), " } ?? ""
            lines.append("\(position)\(ProgramPlan.title(program).lowercased()) week: \(ProgramPlan.why(program))")
        } else if light {
            lines.append("A deload week: the same kind of work at about half the sets and lighter loads.")
        }
        if !request.goals.isEmpty { lines.append("Goals: \(request.goals.joined(separator: "; ")).") }
        if let brief = request.brief {
            lines.append("This phase's plan: \(brief.focus). Main lifts: \(brief.mainLifts.joined(separator: ", ")), around \(brief.mainReps) reps; the rest around \(brief.accessoryReps).")
        }
        if !light { lines += aims(request) }
        if !request.progression.isEmpty {
            lines.append("Main lifts' top sets this week, decided from how they went; keep to them:\n"
                         + request.progression.map { Progression.line($0, names: request.names) }.joined(separator: "\n"))
        }
        let low = light ? max(1, Int(Double(range.lowerBound) * TrainingGenerator.deloadSets)) : range.lowerBound
        let high = light ? max(1, Int(Double(range.upperBound) * TrainingGenerator.deloadSets)) : range.upperBound
        let sets = low == high ? "about \(low)" : "\(low)–\(high)"
        lines.append("Training days: \(days.map { weekdays[$0 % 7] }.joined(separator: ", ")), \(settings.sessionMinutes) minutes each.")
        let reps = settings.style.reps
        // The brief's reps, when there is one, stand for the style's.
        lines.append("Age \(settings.age)\(settings.bodyWeight.map { ", \(Coach.number($0)) lb" } ?? ""). Style: \(settings.style.rawValue)"
                     + (request.brief == nil ? " (main lifts around \(Int(reps.main)) reps, the rest around \(Int(reps.accessory)))." : "."))
        lines.append("Equipment: \(settings.equipment.isEmpty ? "none, bodyweight only" : settings.equipment.sorted().map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).")
        if !settings.injuredAreas.isEmpty { lines.append("Injured: \(settings.injuredAreas.sorted().joined(separator: ", ")).") }
        if !settings.avoidExercises.isEmpty {
            lines.append("Never: \(settings.avoidExercises.sorted().map { request.names[$0] ?? $0 }.joined(separator: ", ")).")
        }
        let last = lastWeek(request)
        if !last.isEmpty { lines.append("Last week's plan:\n" + last) }
        lines += lastWeekDone(request)
        if let sleep = request.sleepHours, sleep < 6.5 { lines.append("Slept \(Coach.number((sleep * 2).rounded() / 2)) h a night on average last week.") }
        if !request.differentFrom.isEmpty {
            var other = request
            other.lastWeek = request.differentFrom
            lines.append("Make it different from this version, with other exercises where you can:\n" + lastWeek(other))
        }
        let top = topSets(request)
        if !top.isEmpty { lines.append("Recent top sets:\n" + top) }
        let starts = settings.starts.compactMap { start -> String? in
            guard let name = request.names[start.exercise] else { return nil }
            if let load = start.value("load_lb"), let reps = start.value("reps") { return "\(name) \(Coach.number(load)) lb × \(Coach.number(reps))" }
            if let reps = start.value("reps") { return "\(name) \(Coach.number(reps)) in a row" }
            if let seconds = start.value("duration_s") { return "\(name) \(Coach.number(seconds)) s" }
            return nil
        }
        if !starts.isEmpty { lines.append("Where they're starting: \(starts.joined(separator: "; ")).") }
        lines.append("Menu, by movement:\n" + menu(request, settings: settings))
        lines.append("Design \(days.count) sessions, each of 4 to 6 exercises and \(sets) working sets.")
        return lines.joined(separator: "\n")
    }

    /// FIT-95: where each goal should be by the end of this week, on the line from its start to its target, and the top
    /// set that would show it: "Bench Press is a goal (225 by Jan 9): estimated max about 190 now; aim for about 201
    /// by the end of this week, a top set near 175 × 5."
    static func aims(_ request: Request) -> [String] {
        guard let index = request.programIndex, request.programPlan.indices.contains(index) else { return [] }
        let since = request.calendar.date(byAdding: .day, value: -56, to: request.monday)!
        let recent = request.history.filter { $0.date < request.monday }
        return request.goalLifts.map { lift in
            let name = request.names[lift.exercise] ?? lift.exercise
            let aim = ProgramPlan.expected(from: lift.start, target: lift.target, at: index, weeks: request.programPlan)
            let by = lift.deadline.map { " by \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            let now = GoalProgress.current("\(lift.exercise).\(lift.measure)", sets: recent, weighIns: [], since: since)
            if lift.measure == "reps" {
                return "\(name) is a goal (\(Coach.number(lift.target)) in a row\(by)): \(now.map { "\(Coach.number($0)) now; " } ?? "")"
                    + "aim for about \(Coach.number(aim.rounded())) in a row by the end of this week."
            }
            // A decided top set stands for the aim's.
            if request.progression.contains(where: { $0.exercise == lift.exercise }) {
                return "\(name) is a goal (\(Coach.number(lift.target)) lb\(by)): aim for an estimated max of about \(Coach.number(aim.rounded())) by the end of this week."
            }
            let reps = Double(request.brief?.mainReps ?? Int(request.settings.style.reps.main))
            return "\(name) is a goal (\(Coach.number(lift.target)) lb\(by)): estimated max about \(Coach.number((now ?? lift.start).rounded())) now; "
                + "aim for about \(Coach.number(aim.rounded())) by the end of this week, a top set near "
                + "\(Coach.number(ProgramPlan.load(forMax: aim, reps: reps))) × \(Coach.number(reps))."
        }
    }

    static let menuMovements = ["squat", "lunge", "hinge", "horizontal push", "vertical push", "horizontal pull",
                                "vertical pull", "core", "carry", "conditioning", "arms"]

    /// The first few exercises find_exercises gives for each movement, so most weeks need no searching.
    private static func menu(_ request: Request, settings: TrainingSettings) -> String {
        menuMovements.compactMap { movement in
            let found = ExerciseSearch.find(movement, in: request.catalog, names: request.names, settings: settings, limit: 4)
            return found.isEmpty ? nil : "\(movement.prefix(1).uppercased() + movement.dropFirst()): \(found.map { request.names[$0] ?? $0 }.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// "Mon Upper: Bench Press 4×5 185 lb, Pull-up 3×8, …", working sets only.
    private static func lastWeek(_ request: Request) -> String {
        var sessions: [(date: Date, name: String, items: [String])] = []
        for row in request.lastWeek where row.note != TrainingGenerator.warmupNote {
            let item = "\(request.names[row.exercise] ?? row.exercise) \(Proposal.dose(row))"
            if let index = sessions.firstIndex(where: { $0.date == row.date }) { sessions[index].items.append(item) }
            else { sessions.append((row.date, row.session, [item])) }
        }
        return sessions.map { session in
            let day = (request.calendar.component(.weekday, from: session.date) + 5) % 7
            return "\(weekdays[day]) \(session.name): \(session.items.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// FIT-96: last week as done, against its plan: "2 of 3 sessions done (Fri skipped)." and each main lift that
    /// went differently: "Bench Press planned 185 × 5, did 185 × 4 at RPE 9.5." Nothing when there was no plan.
    static func lastWeekDone(_ request: Request) -> [String] {
        let planned = request.lastWeek.filter { $0.note != TrainingGenerator.warmupNote }
        guard !planned.isEmpty else { return [] }
        let calendar = request.calendar
        let days = Set(planned.map { calendar.startOfDay(for: $0.date) }).sorted()
        func logged(on day: Date) -> [LoggedSet] { request.history.filter { calendar.isDate($0.date, inSameDayAs: day) } }
        let skipped = days.filter { logged(on: $0).isEmpty }
        func weekday(_ day: Date) -> String { weekdays[(calendar.component(.weekday, from: day) + 5) % 7] }
        var lines = ["Last week: \(days.count - skipped.count) of \(days.count) sessions done"
                     + (skipped.isEmpty ? "." : " (\(skipped.map(weekday).joined(separator: ", ")) skipped).")]
        var differed: [String] = []
        for row in planned where row.main && !skipped.contains(calendar.startOfDay(for: row.date)) {
            let name = request.names[row.exercise] ?? row.exercise
            let sets = logged(on: row.date).filter { $0.exercise == row.exercise }
            let plannedLoad = row.target("load_lb") ?? row.target("load_lb_hand"), plannedReps = row.target("reps")
            let plan = [plannedLoad.map(Coach.number), plannedReps.map(Coach.number)].compactMap { $0 }.joined(separator: " × ")
            guard let top = sets.max(by: { ($0.value("load_lb") ?? $0.value("load_lb_hand") ?? 0, $0.value("reps") ?? 0)
                                           < ($1.value("load_lb") ?? $1.value("load_lb_hand") ?? 0, $1.value("reps") ?? 0) }) else {
                differed.append("\(name) planned \(plan), not done.")
                continue
            }
            // The set that fell short, or the hardest: the last rep missed shows there.
            let short = sets.first { ($0.value("reps") ?? .infinity) < (plannedReps ?? 0) } ?? top
            let load = short.value("load_lb") ?? short.value("load_lb_hand"), reps = short.value("reps"), rpe = sets.compactMap { $0.value("rpe") }.max()
            let lighter = (load ?? 0) < (plannedLoad ?? 0), fewer = (reps ?? .infinity) < (plannedReps ?? 0), hard = (rpe ?? 0) >= 9
            guard lighter || fewer || hard else { continue }
            let did = [load.map(Coach.number), reps.map(Coach.number)].compactMap { $0 }.joined(separator: " × ")
            differed.append("\(name) planned \(plan), did \(did)\(rpe.map { " at RPE \(Coach.number($0))" } ?? "").")
        }
        if !differed.isEmpty { lines.append(differed.prefix(4).joined(separator: " ")) }
        return lines
    }

    /// The last 4 weeks' best set of each exercise, most recent first: "Bench Press 185 lb × 5 at RPE 8, 6 days ago".
    private static func topSets(_ request: Request) -> String {
        let since = request.calendar.date(byAdding: .day, value: -28, to: request.monday)!
        let recent = request.history.filter { $0.date >= since && $0.date < request.monday }
        let byExercise = Dictionary(grouping: recent, by: \.exercise)
        let lines = byExercise.compactMap { slug, sets -> (Date, String)? in
            guard let name = request.names[slug], let day = sets.map(\.date).max() else { return nil }
            let last = sets.filter { request.calendar.isDate($0.date, inSameDayAs: day) }
            let top = last.max { ($0.value("load_lb") ?? $0.value("load_lb_hand") ?? 0, $0.value("reps") ?? 0, $0.value("duration_s") ?? 0)
                < ($1.value("load_lb") ?? $1.value("load_lb_hand") ?? 0, $1.value("reps") ?? 0, $1.value("duration_s") ?? 0) }!
            var text = name
            if let load = top.value("load_lb") { text += " \(Coach.number(load)) lb" }
            if let load = top.value("load_lb_hand") { text += " \(Coach.number(load)) lb each hand" }
            if let reps = top.value("reps") { text += " × \(Coach.number(reps))" }
            if let seconds = top.value("duration_s") { text += " \(Coach.number(seconds)) s" }
            if let meters = top.value("distance_m") { text += " \(Coach.number(meters)) m" }
            if let rpe = top.value("rpe") { text += " at RPE \(Coach.number(rpe))" }
            let ago = request.calendar.dateComponents([.day], from: request.calendar.startOfDay(for: day),
                                                      to: request.monday).day ?? 0
            return (day, "\(text), \(ago) days ago")
        }
        return lines.sorted { $0.0 > $1.0 }.prefix(16).map(\.1).joined(separator: "\n")
    }

    // MARK: Tool

    final class Log: Sendable {
        let calls = Mutex<[String]>([])
    }

    struct FindExercises: Tool {
        let name = "find_exercises"
        let description = """
            Exercises they can do with their equipment and limits, for a movement (squat, hinge, lunge, push, pull, \
            carry, core, arms, shoulders, legs, calves, conditioning), a plane (vertical pull, horizontal push), a muscle \
            (hamstrings, chest) or words of a name (curl).
            """
        let request: Request
        let settings: TrainingSettings
        let log: Log

        @Generable
        struct Arguments {
            @Guide(description: "A movement, plane, muscle or name, like hinge, vertical pull, glutes or curl")
            var query: String
        }

        func call(arguments: Arguments) async throws -> String {
            // A model that keeps searching never designs the week.
            // Each search's answer takes room in the model's 4K-token context, and a model that keeps searching never
            // designs the week.
            if log.calls.withLock({ $0.count >= 4 }) { return "That's enough searching. Design the week now." }
            log.calls.withLock { $0.append("find_exercises \(arguments.query)") }
            var found = ExerciseSearch.find(arguments.query, in: request.catalog, names: request.names, settings: settings, limit: 6)
            if found.isEmpty {
                found = PlanGuard.search(arguments.query, in: request.catalog, names: request.names, settings: settings, limit: 6)
            }
            guard !found.isEmpty else {
                return "Nothing for \(arguments.query) with their equipment. Try a movement, like push or hinge."
            }
            return found.map { request.names[$0] ?? $0 }.joined(separator: ", ")
        }
    }

    // MARK: Names

    /// Names the catalog doesn't have go back to the model once, each with its closest options. What's still
    /// unresolved is left for PlanGuard's own search to repair.
    private static func rename(_ designed: inout DesignedWeek, _ request: Request, settings: TrainingSettings, log: Log,
                               model: any AIModel) async throws {
        let bySlug = Dictionary(request.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let unresolved = designed.sessions.flatMap(\.exercises).map(\.name)
            .filter { PlanGuard.resolve($0, in: bySlug, names: request.names) == nil }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let options = unresolved.compactMap { name -> (String, [String])? in
            let found = PlanGuard.search(name, in: request.catalog, names: request.names, settings: settings, limit: 6)
            return found.isEmpty ? nil : (name, found.map { request.names[$0] ?? $0 })
        }
        guard !options.isEmpty else { return }
        log.calls.withLock { $0.append("rename \(options.map(\.0).joined(separator: ", "))") }
        let session = model.session(instructions: """
            These exercises aren't in the user's catalog. For each, choose the closest of its options, written exactly.
            """)
        let renames = try await session.respond(
            to: options.map { "\($0.0): \($0.1.joined(separator: ", "))" }.joined(separator: "\n"),
            generating: Renames.self)
        let map = Dictionary(renames.exercises.filter { rename in options.contains { $0.0 == rename.from && $0.1.contains(rename.to) } }
            .map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
        for s in designed.sessions.indices {
            for e in designed.sessions[s].exercises.indices {
                if let to = map[designed.sessions[s].exercises[e].name] { designed.sessions[s].exercises[e].name = to }
            }
        }
    }

    // MARK: First loads

    /// The weighted exercises the model gave no load: the ones code can't dose without one. Those with a load in the
    /// history or starting points aren't asked about; the model left them empty on purpose only if it forgot.
    static func missingLoads(_ designed: DesignedWeek, _ request: Request) -> [String] {
        let bySlug = Dictionary(request.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        return designed.sessions.flatMap(\.exercises).filter { item in
            guard item.pounds == nil, let exercise = PlanGuard.resolve(item.name, in: bySlug, names: request.names) else { return false }
            return !exercise.isTimed && !exercise.equipment.isDisjoint(with: loadBearing)
        }.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// FIT-73: every weighted exercise starts with a load the model chose. One more ask for those it left empty, with
    /// what's known to go on; PlanGuard then holds each to its ceiling.
    private static func fillLoads(_ designed: inout DesignedWeek, _ request: Request, settings: TrainingSettings, log: Log,
                                  model: any AIModel) async throws {
        let missing = missingLoads(designed, request)
        guard !missing.isEmpty else { return }
        log.calls.withLock { $0.append("first loads \(missing.joined(separator: ", "))") }
        let known = [topSets(request), settings.starts.compactMap { start -> String? in
            guard let name = request.names[start.exercise], let load = start.value("load_lb"), let reps = start.value("reps") else { return nil }
            return "\(name) \(Coach.number(load)) lb × \(Coach.number(reps))"
        }.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n")
        let session = model.session(instructions: """
            You're a strength coach choosing a light first load for each exercise, from a related lift they know: each \
            dumbbell for a dumbbell bench is about 40% of the barbell bench, an overhead press about 65% of it, a row \
            about 80%, a lunge about 60% of the squat.
            """)
        let prompt = "Age \(settings.age)\(settings.bodyWeight.map { ", \(Coach.number($0)) lb" } ?? "").\n"
            + (known.isEmpty ? "No lifts known yet.\n" : "What they lift:\n\(known)\n")
            + "First loads for: \(missing.joined(separator: ", "))."
        let loads = try await session.respond(to: prompt, generating: FirstLoads.self).loads
        let byName = Dictionary(loads.filter { missing.contains($0.name) }.map { ($0.name, $0.pounds) }, uniquingKeysWith: { first, _ in first })
        for s in designed.sessions.indices {
            for e in designed.sessions[s].exercises.indices where designed.sessions[s].exercises[e].pounds == nil {
                designed.sessions[s].exercises[e].pounds = byName[designed.sessions[s].exercises[e].name]
            }
        }
    }

    // MARK: Rows

    static let loadBearing: Set<String> = ["barbell", "dumbbells", "kettlebells", "ez_bar", "trap_bar", "cable", "machine",
                                           "sled", "medicine_ball"]

    /// The design as planned rows on the training days; when it has fewer sessions than days, they repeat in order
    /// (an A/B split over 3 days is A, B, A). Main lifts get fitness-planner's warm-up and their tier's tempo.
    static func rows(_ designed: DesignedWeek, _ request: Request, settings: TrainingSettings, tier: AgeTier)
        -> (workouts: [PlannedWorkout], why: [String]) {
        let sessions = designed.sessions.filter { !$0.exercises.isEmpty }
        guard !sessions.isEmpty else { return ([], []) }
        let bySlug = Dictionary(request.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        var workouts: [PlannedWorkout] = [], why: [String] = []
        for (index, day) in settings.trainingDays.prefix(settings.daysPerWeek).enumerated() {
            let session = sessions[index % sessions.count]
            if index < sessions.count { why.append("\(session.name): \(session.why)") }
            let date = request.calendar.date(byAdding: .minute, value: settings.workoutTime,
                                             to: Week.date(day, in: request.monday, calendar: request.calendar))!
            for item in session.exercises {
                let exercise = PlanGuard.resolve(item.name, in: bySlug, names: request.names)
                let slug = exercise?.slug ?? item.name
                var targets = [Measurement(metric: "sets", value: Double(item.sets), unit: "sets")]
                let timed = exercise?.isTimed ?? (item.seconds != nil)
                let carry = exercise?.pattern == "carry" || (exercise == nil && item.meters != nil)
                if timed {
                    targets.append(Measurement(metric: "duration_s", value: Double(item.seconds ?? item.reps ?? 45), unit: "s"))
                } else if carry {
                    targets.append(Measurement(metric: "distance_m", value: Double(item.meters ?? 30), unit: "m"))
                } else {
                    targets.append(Measurement(metric: "reps", value: Double(item.reps ?? Int(item.main ? settings.style.reps.main : settings.style.reps.accessory)),
                                               unit: "reps"))
                }
                // A load on a bodyweight exercise ("Pull-up 1 lb") is noise, not a choice.
                let loadable = exercise.map { !$0.equipment.isDisjoint(with: loadBearing) } ?? true
                if let pounds = item.pounds, pounds > 0, loadable {
                    // Dumbbells and kettlebells are planned per hand, as they're logged.
                    let logged = request.history.last { $0.exercise == slug && ($0.value("load_lb") ?? $0.value("load_lb_hand")) != nil }
                    let perHand = logged.map { $0.value("load_lb_hand") != nil }
                        ?? (exercise.map { !$0.equipment.isDisjoint(with: ["dumbbells", "kettlebells"]) && !$0.equipment.contains("barbell") } ?? false)
                    targets.append(perHand ? Measurement(metric: "load_lb_hand", value: Double(pounds), unit: "lb/hand")
                                           : Measurement(metric: "load_lb", value: Double(pounds), unit: "lb"))
                }
                if !timed, !carry, let rpe = item.rpe { targets.append(Measurement(metric: "rpe", value: Double(rpe), unit: "RPE")) }
                let row = PlannedWorkout(date: date, session: session.name, exercise: slug, targets: targets,
                                         // Main lifts go in straight sets after their warm-up; supersets are for the rest.
                                         note: item.main ? tier.tempo.map { "tempo \($0)" } : nil, group: item.main ? nil : item.superset,
                                         main: item.main)
                if item.main, let warmup = TrainingGenerator.warmup(for: row, settings: settings, tier: tier) { workouts.append(warmup) }
                workouts.append(row)
            }
        }
        return (workouts, why)
    }
}
