import Foundation
import Testing
@testable import AICoach

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private struct Inputs: Sendable {
    var catalog: [Exercise]
    var names: [String: String]
    var history: [LoggedSet]
}

/// The seed catalog and the author's imported history (FIT-13).
private let inputs: Inputs = {
    let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    let patterns = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.pattern) })
    let history = try! Seeder.decode([LogSeed].self, "history", .main)
        .filter { $0.kind == .workout }
        .map { LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: patterns[$0.template ?? ""],
                         measurements: $0.measurements) }
    return Inputs(catalog: catalog, names: Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) }),
                  history: history)
}()

/// FIT-68: the generator run across a grid of realistic settings, with every session checked against what a coach
/// would accept. Unit tests check one rule at a time; this catches the combinations (12 sets of bench).
@MainActor
struct ProgramEvalTests {
    // MARK: Grid

    private enum Gear: String, CaseIterable {
        case gym, dumbbells, travel, bodyweight

        var equipment: Set<String> {
            switch self {
            case .gym, .travel: ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"]
            case .dumbbells: ["dumbbells", "bench"]
            case .bodyweight: []
            }
        }
    }

    private enum Limit: String, CaseIterable {
        case none, knees, lowerBack = "lower back", avoids = "no bench or pull-ups"

        func apply(_ settings: inout TrainingSettings) {
            switch self {
            case .none: break
            case .knees, .lowerBack: settings.injuredAreas = BodyArea.muscles(for: [rawValue])
            case .avoids: settings.avoidExercises = ["bench-press", "pull-up"]
            }
        }
    }

    private struct Scenario: CustomStringConvertible {
        var days: Int
        var minutes: Int
        var style: TrainingStyle
        var age: Int
        var gear: Gear
        var limit: Limit
        /// nil: outside a program, by weeks since the last deload.
        var kind: ProgramWeek.Kind?
        var withHistory: Bool

        var description: String {
            [ "\(days)d/\(minutes)m", style.rawValue, "\(age)y", gear.rawValue, limit == .none ? nil : limit.rawValue,
              kind?.rawValue ?? "no program", withHistory ? "history" : "no history" ].compactMap { $0 }.joined(separator: ", ")
        }

        var settings: TrainingSettings {
            let days = [2: [0, 3], 3: [0, 2, 4], 4: [0, 1, 3, 4], 5: [0, 1, 2, 3, 4], 6: [0, 1, 2, 3, 4, 5]][days]!
            var settings = TrainingSettings(
                age: age, daysPerWeek: days.count, sessionMinutes: minutes, trainingDays: days, workoutTime: 7 * 60,
                equipment: gear.equipment, maxWeeklySets: 60, style: style, warmups: true,
                // Onboarding asks where you're starting; without history these are what loads come from.
                starts: withHistory ? [] : [
                    StartingSet(exercise: "back-squat", measurements: [.init(metric: "load_lb", value: 185, unit: "lb"),
                                                                      .init(metric: "reps", value: 5, unit: "reps")]),
                    StartingSet(exercise: "bench-press", measurements: [.init(metric: "load_lb", value: 155, unit: "lb"),
                                                                       .init(metric: "reps", value: 5, unit: "reps")]),
                    StartingSet(exercise: "deadlift", measurements: [.init(metric: "load_lb", value: 225, unit: "lb"),
                                                                    .init(metric: "reps", value: 5, unit: "reps")]),
                    StartingSet(exercise: "push-up", measurements: [.init(metric: "reps", value: 25, unit: "reps")]),
                    StartingSet(exercise: "plank", measurements: [.init(metric: "duration_s", value: 60, unit: "s")]),
                ])
            limit.apply(&settings)
            return settings
        }

        var program: ProgramWeek? {
            let travel = gear == .travel
            guard let kind else { return travel ? ProgramWeek(phase: .base, kind: .base, travel: true) : nil }
            let phase: ProgramPhase = switch kind {
            case .build: .build
            case .peak, .test: .peak
            default: .base
            }
            return ProgramWeek(phase: phase, kind: kind, travel: travel)
        }

        /// The week after the imported history ends, or the week onboarding finishes.
        var monday: Date {
            Week.monday(of: calendar.date(from: DateComponents(year: 2026, month: withHistory ? 7 : 10,
                                                                                day: withHistory ? 20 : 5))!,
                        calendar: calendar)
        }

        func week(kind override: ProgramWeek.Kind?? = nil) -> TrainingWeek {
            var scenario = self
            if let override { scenario.kind = override }
            return TrainingGenerator.week(startingOn: monday, settings: settings, catalog: inputs.catalog,
                                          history: withHistory ? inputs.history : [],
                                          weeksSinceDeload: 0, program: scenario.program, calendar: calendar)
        }
    }

    /// Every days × minutes × style × gear × week kind × history; age and limits vary across them with coprime
    /// strides, so each meets every other dimension without a full product.
    private static var scenarios: [Scenario] {
        let ages = [25, 36, 45, 55, 65]
        let kinds: [ProgramWeek.Kind?] = [nil, .base, .build, .peak, .deload, .test]
        var result: [Scenario] = []
        var i = 0
        for days in 2...6 {
            for minutes in [30, 45, 60, 90] {
                for style in TrainingStyle.allCases {
                    for gear in Gear.allCases {
                        for kind in kinds {
                            for history in [false, true] {
                                result.append(Scenario(days: days, minutes: minutes, style: style, age: ages[i % ages.count],
                                                       gear: gear, limit: Limit.allCases[(i / 7) % Limit.allCases.count],
                                                       kind: kind, withHistory: history))
                                i += 1
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: Invariants

    /// General practice: fitness-planner's CLAUDE.md caps sets per session and week, not per exercise.
    static let maxSets = (main: 5, accessory: 4)

    /// plan.md step 7 for powerbuilding (3–6 compound, 8–15 accessory); the other styles are general practice.
    private static func repRange(_ style: TrainingStyle, main: Bool) -> ClosedRange<Double> {
        switch (style, main) {
        case (.powerlifting, true): 1...6
        case (.powerlifting, false): 5...12
        case (.powerbuilding, true): 3...6
        case (.powerbuilding, false): 8...15
        case (.hypertrophy, _): 6...15
        case (.functional, _): 5...15
        }
    }

    /// Brzycki from the best logged set of each exercise (fitness-planner CLAUDE.md "1RM Estimation": 1–10 reps),
    /// counting the reps left in reserve (10 − RPE, 2 when unlogged): 155×5 at RPE 7 is an 8-rep max, not a 5-rep one.
    private static let estimatedMaxes: [String: Double] = Dictionary(
        inputs.history.compactMap { set -> (String, Double)? in
            guard let load = set.value("load_lb"), let reps = set.value("reps"), (1...10).contains(reps) else { return nil }
            let reserve = 10 - min(max(set.value("rpe") ?? 8, 6), 10)
            return (set.exercise, ProgramPlan.estimatedMax(load: load, reps: reps + reserve))
        }, uniquingKeysWith: max)

    private func name(_ slug: String) -> String { inputs.names[slug] ?? slug }

    private func dose(_ row: PlannedWorkout) -> String {
        var dose = "\(Int(row.target("sets") ?? 0))×"
        dose += row.target("duration_s").map { "\(Int($0))s" } ?? row.target("distance_m").map { "\(Int($0))m" }
            ?? row.target("reps").map { "\(Int($0))" } ?? "?"
        if let load = row.target("load_lb") { dose += " @\(Coach.number(load))" }
        if let load = row.target("load_lb_hand") { dose += " @\(Coach.number(load))/hand" }
        return dose
    }

    private func render(_ rows: [PlannedWorkout]) -> String {
        rows.filter { $0.note != TrainingGenerator.warmupNote }.map { "\(name($0.exercise)) \(dose($0))" }
            .joined(separator: ", ")
    }

    /// What's wrong with one session, as "Bench Press 12×8 ← over the 5-set cap".
    private func problems(session rows: [PlannedWorkout], settings: TrainingSettings, travel: Bool, light: Bool,
                          range: ClosedRange<Int>?) -> [String] {
        let tier = AgeTier.of(age: settings.age)
        var allowed = settings
        if travel { allowed.equipment.formIntersection(ProgramPlan.travelEquipment) }
        let bySlug = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let working = rows.filter { $0.note != TrainingGenerator.warmupNote }
        let mains = Set(rows.filter { $0.note == TrainingGenerator.warmupNote }.map(\.exercise))
        var problems: [String] = []
        func flag(_ row: PlannedWorkout, _ why: String) { problems.append("\(name(row.exercise)) \(dose(row)) ← \(why)") }

        for row in working {
            let sets = Int(row.target("sets") ?? 0)
            // The main lift is the one with a warm-up; one without a load gets none, but it's dosed at the style's main
            // reps. A goal lift may be either, so it gets the main cap.
            let main = mains.contains(row.exercise) || bySlug[row.exercise]?.isGoalLift == true
                || (settings.style.reps.main != settings.style.reps.accessory && row.target("reps") == settings.style.reps.main)
            let cap = main ? Self.maxSets.main : Self.maxSets.accessory
            if sets > cap { flag(row, "over the \(cap)-set cap") }
            if sets < 2 && !light { flag(row, "a single set") }
            if let reps = row.target("reps"), row.target("load_lb") != nil {
                let range = Self.repRange(settings.style, main: mains.contains(row.exercise))
                if !range.contains(reps) { flag(row, "\(Int(reps)) reps is outside \(settings.style.rawValue)'s \(Int(range.lowerBound))–\(Int(range.upperBound))") }
            }
            if let reps = row.target("reps"), !(1...30).contains(reps) { flag(row, "\(Int(reps)) reps") }
            if let rpe = row.target("rpe") {
                let cap = light ? TrainingGenerator.deloadRPE : tier.topRPE
                if rpe > cap { flag(row, "RPE \(Coach.number(rpe)) over \(Coach.number(cap))") }
            }
            // Barbell loads only: a per-hand load is the dumbbell or kettlebell owned (24 kg is 52.9 lb).
            if let load = row.target("load_lb"), load.truncatingRemainder(dividingBy: 5) != 0 { flag(row, "\(Coach.number(load)) lb isn't a multiple of 5") }
            if let load = row.target("load_lb"), let reps = row.target("reps"), let max = Self.estimatedMaxes[row.exercise] {
                // The most the history says can be done for those reps, plus one 5 lb step of progression.
                let ceiling = max * (37 - min(reps, 36)) / 36 + 5
                if load > ceiling { flag(row, "over the \(Coach.number(ceiling.rounded())) lb e1RM allows for \(Int(reps)) reps") }
                if load < max * 0.4 { flag(row, "under 40% of the \(Coach.number(max.rounded())) lb e1RM") }
            }
            if let exercise = bySlug[row.exercise], !TrainingGenerator.allows(exercise, allowed) {
                flag(row, "not allowed (equipment, injury or avoided)")
            }
        }
        let slugs = working.map(\.exercise)
        if Set(slugs).count != slugs.count { problems.append("an exercise repeats: \(slugs.map(name).joined(separator: ", "))") }
        let mainPatterns = mains.compactMap { bySlug[$0] }
        if mainPatterns.contains(where: { $0.pattern == "squat" }) && mains.contains("deadlift") {
            problems.append("squat and deadlift are both main lifts")
        }
        let total = working.reduce(0) { $0 + Int($1.target("sets") ?? 0) }
        if let range, total > range.upperBound { problems.append("\(total) sets is over the session's \(range.upperBound)") }
        return problems
    }

    /// The session's working-set range the volume table gives, as the generator reads it.
    private func range(_ settings: TrainingSettings, program: ProgramWeek?) -> ClosedRange<Int> {
        let range = VolumePlan.of(daysPerWeek: settings.daysPerWeek, sessionMinutes: settings.sessionMinutes).setsPerSession
        return program.map { ProgramPlan.sessionSets(range, phase: $0.phase) } ?? range
    }

    private func check(_ scenario: Scenario) -> [String] {
        let settings = scenario.settings
        let week = scenario.week()
        let light = week.deload || scenario.program?.light == true
        let range = range(settings, program: scenario.program)
        var failures: [String] = []
        let sessions = Dictionary(grouping: week.workouts, by: \.date).sorted { $0.key < $1.key }
        for (_, rows) in sessions {
            let session = rows[0].session
            var problems = problems(session: rows, settings: settings, travel: scenario.gear == .travel, light: light,
                                    range: light ? nil : range)
            let total = rows.filter { $0.note != TrainingGenerator.warmupNote }.reduce(0) { $0 + Int($1.target("sets") ?? 0) }
            if !light, total < range.lowerBound, !week.warnings.contains(where: { $0.contains(session) }) {
                problems.append("\(total) sets is under the session's \(range.lowerBound) with no warning")
            }
            if !problems.isEmpty {
                failures.append("\(session), \(scenario): \(render(rows))\n    " + problems.joined(separator: "\n    "))
            }
        }
        if week.totalSets > settings.maxWeeklySets, !week.warnings.contains(where: { $0.contains("ceiling") }) {
            failures.append("\(scenario): \(week.totalSets) weekly sets over \(settings.maxWeeklySets) with no warning")
        }
        // A deload is about half the sets of the same week at full volume (plan.md step 4: −40–50%).
        if scenario.kind == .deload {
            let full = scenario.week(kind: .some(scenario.program!.phase == .build ? .build : .base)).totalSets
            let ratio = Double(week.totalSets) / Double(max(full, 1))
            if full > 0, !(0.4...0.7).contains(ratio) {
                failures.append("\(scenario): deload has \(week.totalSets) sets against \(full) at full volume")
            }
        }
        return failures
    }

    /// How many failed, a tally by reason, then the first few in full.
    private func report(_ failures: [String], of count: Int) -> Comment {
        let reasons = failures.flatMap { $0.split(separator: "\n").dropFirst() }.map { line in
            String(line.split(separator: "← ").last ?? line).replacing(/\d+(\.\d+)?/, with: "N").trimmingCharacters(in: .whitespaces)
        }
        let tally = Dictionary(reasons.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
            .map { "  \($0.value)× \($0.key)" }.joined(separator: "\n")
        return Comment(rawValue: "\(failures.count) failing sessions in \(count) scenarios.\n\(tally)\n\nFirst \(min(failures.count, 25)):\n\n"
            + failures.prefix(25).joined(separator: "\n\n"))
    }

    // MARK: Sweeps

    @Test func everyWeekInTheGridPasses() {
        let scenarios = Self.scenarios
        let failures = scenarios.flatMap(check)
        #expect(failures.count == 0, report(failures, of: scenarios.count))
    }

    /// Spoken rebuilds ("leg day", "dumbbells only", "a quick one") go through the same rules.
    @Test func everyRebuiltSessionPasses() {
        var failures: [String] = [], count = 0
        let base = Scenario(days: 3, minutes: 60, style: .powerbuilding, age: 36, gear: .gym, limit: .none, kind: nil,
                            withHistory: true)
        for history in [false, true] {
            var scenario = base
            scenario.withHistory = history
            let settings = scenario.settings
            let date = calendar.date(byAdding: .hour, value: 7, to: scenario.monday)!
            let today = scenario.week().workouts.filter { calendar.isDate($0.date, inSameDayAs: date) }
            let setup = TodayWorkout.Setup(names: inputs.names, catalog: inputs.catalog, settings: settings,
                                           history: history ? inputs.history : [], weeksSinceDeload: 0, date: date,
                                           session: today.first?.session ?? "Today", calendar: calendar)
            for focus in TodayWorkout.Focus.allCases {
                for gear in TodayWorkout.Equipment.allCases {
                    for minutes in [nil, 15, 30, 45] as [Int?] {
                        count += 1
                        var workout = TodayWorkout(today, setup: setup)
                        guard workout.regenerate(focus, equipment: gear, minutes: minutes) == nil else { continue }
                        var range = range(settings, program: nil)
                        if let minutes {
                            let scale = Double(minutes) / Double(settings.sessionMinutes)
                            range = max(3, Int(Double(range.lowerBound) * scale))...max(3, Int(Double(range.upperBound) * scale))
                        }
                        var allowed = settings
                        switch gear {
                        case .all: break
                        case .dumbbells: allowed.equipment.formIntersection(["dumbbells"])
                        case .bodyweight: allowed.equipment = []
                        case .noBarbell: allowed.equipment.subtract(["barbell", "rack"])
                        }
                        let problems = problems(session: workout.rows, settings: allowed, travel: false, light: false, range: range)
                        if !problems.isEmpty {
                            failures.append("\(focus.rawValue), \(gear.rawValue), \(minutes.map { "\($0) min" } ?? "full length"), \(history ? "history" : "no history"): \(render(workout.rows))\n    "
                                            + problems.joined(separator: "\n    "))
                        }
                    }
                }
            }
        }
        #expect(failures.count == 0, report(failures, of: count))
    }

    // MARK: Regressions

    /// The author's 12 sets of bench: a push-pull-legs Push day is bench, one push accessory and core (9 sets);
    /// filling 16 put the other 7 on bench.
    @Test func pushDayDoesNotPileSetsOnBench() {
        let scenario = Scenario(days: 5, minutes: 60, style: .powerbuilding, age: 36, gear: .gym, limit: .none, kind: nil,
                                withHistory: true)
        let push = scenario.week().workouts.filter { $0.session == "Push" && $0.note != TrainingGenerator.warmupNote }
        #expect(!push.isEmpty)
        #expect(push.allSatisfy { ($0.target("sets") ?? 0) <= Double(Self.maxSets.main) }, "\(render(push))")
        #expect(push.reduce(0) { $0 + ($1.target("sets") ?? 0) } >= 16, "\(render(push))")
    }

    /// An empty slot: nothing but bench is allowed on Push day, so the session is short and says so.
    @Test func aSessionWithNothingToFillItIsShortWithAWarning() {
        var scenario = Scenario(days: 5, minutes: 60, style: .powerbuilding, age: 36, gear: .gym, limit: .none, kind: nil,
                                withHistory: true)
        scenario.limit = .none
        var settings = scenario.settings
        settings.avoidExercises = ["dumbbell-bench-press", "push-up", "plank", "dead-bug"]
        let week = TrainingGenerator.week(startingOn: scenario.monday, settings: settings, catalog: inputs.catalog,
                                          history: inputs.history, weeksSinceDeload: 0, calendar: calendar)
        let push = week.workouts.filter { $0.session == "Push" && $0.note != TrainingGenerator.warmupNote }
        #expect(push.map(\.exercise) == ["bench-press"])
        #expect(push.first?.target("sets") == Double(Self.maxSets.main))
        #expect(week.warnings.contains { $0.hasPrefix("Push is") }, "\(week.warnings)")
    }

    // MARK: Samples

    /// The author's settings (fitness-planner config.yaml) through a program, to read like a coach would.
    /// Printed to the test log; also written to the temporary directory as program-samples.txt.
    @Test func sampleWeeks() throws {
        var text = ""
        for kind in [ProgramWeek.Kind.base, .build, .peak, .deload] {
            let scenario = Scenario(days: 3, minutes: 45, style: .powerbuilding, age: 36, gear: .gym, limit: .none,
                                    kind: kind, withHistory: true)
            let week = scenario.week()
            text += "\(kind.rawValue.capitalized) week, \(scenario): \(week.totalSets) sets\n"
            for (_, rows) in Dictionary(grouping: week.workouts, by: \.date).sorted(by: { $0.key < $1.key }) {
                text += "  \(rows[0].session): \(render(rows))\n"
            }
            for warning in week.warnings { text += "  ! \(warning)\n" }
        }
        print(text)
        try text.write(to: FileManager.default.temporaryDirectory.appending(path: "program-samples.txt"), atomically: true,
                       encoding: .utf8)
    }
}
