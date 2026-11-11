import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
private let names = Dictionary(seeds.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
private let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
/// The author's real history (CLAUDE.md §6), which ends on 19 July 2026.
private let authorHistory: [LoggedSet] = (try! Seeder.decode([LogSeed].self, "history", .main)).filter { $0.kind == .workout }.map {
    LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: bySlug[$0.template ?? ""]?.pattern, measurements: $0.measurements)
}
/// The Sunday after the author's history ends: every run starts here.
private let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 19))!

/// FIT-425: the week code builds for a free lifter (mode 1) clears a written bar, run for each ready program's whole
/// length and the generator's, on the author's history and four scripted ones: every training day has its session,
/// loads move by the program's step from what was logged, deloads are lighter, nothing outside the equipment or on a
/// sore area, and weekly sets in range.
struct WeekQualityTests {
    enum Lifter: String, CaseIterable, Sendable {
        case author = "the author's history"
        case beginner = "a beginner"
        case missed = "a missed week (week 4)"
        case stalled = "a stalled lift (every main lift two reps short at RPE 10 from week 3)"
        case pain = "sore knees"
    }

    /// One planned week and what was logged after it.
    struct Run {
        var weeks: [TrainingWeek] = []
        var history: [LoggedSet] = []
        var problems: [String] = []
    }

    private static func days(_ count: Int) -> [Int] {
        switch count {
        case 2: [0, 3]
        case 3: [0, 2, 4]
        case 4: [0, 1, 3, 4]
        case 5: [0, 1, 2, 3, 4]
        default: Array(0..<min(count, 6))
        }
    }

    private static func settings(_ ready: ReadyProgram?, lifter: Lifter) -> TrainingSettings {
        let equipment = ready.map { Set($0.equipment + ($0.optional ?? [])) } ?? ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"]
        let count = ready?.days.first(where: { $0 == 3 }) ?? ready?.days.first ?? 3
        var settings = TrainingSettings(age: 36, daysPerWeek: count, sessionMinutes: ready?.minutes ?? 45, trainingDays: days(count),
                                        workoutTime: 7 * 60, equipment: equipment, maxWeeklySets: 60)
        if lifter == .pain { settings.injuredAreas = BodyArea.muscles(for: ["knees"]) }
        return settings
    }

    private static func working(_ week: TrainingWeek) -> [PlannedWorkout] {
        week.workouts.filter { $0.note != TrainingGenerator.warmupNote }
    }

    private static func load(_ row: PlannedWorkout) -> Double? { row.target("load_lb") ?? row.target("load_lb_hand") }
    private static func load(_ set: LoggedSet) -> Double? { set.value("load_lb") ?? set.value("load_lb_hand") }

    /// Each set done as planned, but for the scripted lifter's twist.
    private static func log(_ week: TrainingWeek, index: Int, lifter: Lifter) -> [LoggedSet] {
        if lifter == .missed && index == 3 { return [] }
        return working(week).flatMap { row -> [LoggedSet] in
            (0..<Int(row.target("sets") ?? 1)).map { _ in
                var measurements = row.targets.filter { $0.metric != "sets" }
                // A set done as planned feels a touch easier than its cap: RPE one under, which the rules progress from.
                measurements = measurements.map { $0.metric == "rpe" ? Measurement(metric: "rpe", value: $0.value - 1, unit: "RPE") : $0 }
                if lifter == .stalled, row.main, index >= 2 {
                    measurements = measurements.map { $0.metric == "reps" ? Measurement(metric: "reps", value: max(1, $0.value - 2), unit: "reps") : $0 }
                        .filter { $0.metric != "rpe" } + [Measurement(metric: "rpe", value: 10, unit: "RPE")]
                }
                return LoggedSet(date: row.date.addingTimeInterval(3600), exercise: row.exercise, pattern: bySlug[row.exercise]?.pattern,
                                 measurements: measurements)
            }
        }
    }

    /// The biggest step a program takes on an exercise; the generator's, a tenth of the load or 10 lb.
    private static func step(_ exercise: String, _ ready: ReadyProgram?, last: Double) -> Double {
        let items = ready?.sessions.flatMap(\.exercises).filter {
            $0.exercise == exercise || ($0.or ?? []).contains(exercise) || ($0.ladder ?? []).contains(exercise)
        } ?? []
        // A ready program's step is 5 lb unless it says.
        let steps = items.map { $0.step ?? 5 }
        return max(steps.max() ?? 0, ready == nil ? max(10, (last * 0.1 / 5).rounded(.up) * 5) : 0)
    }

    static func run(_ ready: ReadyProgram?, _ lifter: Lifter) -> Run {
        let settings = settings(ready, lifter: lifter)
        let weeks = ready?.weeks ?? 12
        let program = ProgramPlan.weeks(count: weeks, deloadEvery: AgeTier.of(age: settings.age).deloadEveryWeeks)
        var run = Run(history: lifter == .author || lifter == .stalled || lifter == .pain ? authorHistory : [])
        let label = "\(ready?.slug ?? "generator"), \(lifter.rawValue)"
        for index in 0..<weeks {
            let monday = calendar.date(byAdding: .day, value: 7 * index, to: start)!
            let week = ready.map {
                $0.week(startingOn: monday, start: start, settings: settings, catalog: catalog, history: run.history, program: program,
                        calendar: calendar)
            } ?? TrainingGenerator.week(startingOn: monday, settings: settings, catalog: catalog, history: run.history,
                                        weeksSinceDeload: Training.weeksSinceDeload(run.history, before: monday, calendar: calendar),
                                        program: program[index], calendar: calendar)
            let rows = working(week)
            let where_ = "\(label), week \(index + 1)"
            // Every training day has its session.
            let planned = Set(rows.map { calendar.startOfDay(for: $0.date) })
            let expected = Set(settings.trainingDays.prefix(settings.daysPerWeek).map { Week.date($0, in: monday, calendar: calendar) })
            if planned != expected { run.problems.append("\(where_): sessions on \(planned.count) of \(expected.count) training days") }
            // Nothing outside the equipment, nothing on a sore area.
            for row in rows where !(bySlug[row.exercise].map { TrainingGenerator.allows($0, settings) } ?? false) {
                run.problems.append("\(where_): \(names[row.exercise] ?? row.exercise) isn't allowed")
            }
            // Weekly sets in range: a ready program's as written (its biggest session each day), the generator's within
            // the profile's ceiling; at least three a session either way.
            let sets = Int(rows.reduce(0) { $0 + ($1.target("sets") ?? 0) })
            // A wave lift is its three wave sets and then 5 × 5 (ReadyProgram.waves).
            let most = ready.map { $0.sessions.map { $0.exercises.reduce(0) { $0 + ($1.wave == true ? 8 : $1.sets) } }.max() ?? 0 }
                .map { $0 * settings.daysPerWeek }
                ?? settings.maxWeeklySets
            if sets > most || sets < settings.daysPerWeek * 3 { run.problems.append("\(where_): \(sets) working sets, most \(most)") }
            // A load never more than the program's step over the last top set logged.
            for row in rows {
                guard let planned = load(row),
                      let last = run.history.filter({ $0.exercise == row.exercise && $0.date < monday }).compactMap(load).max() else { continue }
                let step = step(row.exercise, ready, last: last)
                if planned > last + step + 0.01 {
                    run.problems.append("\(where_): \(names[row.exercise] ?? row.exercise) \(Coach.number(last)) → \(Coach.number(planned)), more than its step of \(Coach.number(step))")
                }
            }
            // A deload is lighter than the week before it.
            if program[index].kind == .deload, let before = run.weeks.last {
                // Fewer working sets, or the same sets at lighter loads (bodyweight work has no load to lighten).
                func sets(_ week: TrainingWeek) -> Double { working(week).reduce(0) { $0 + ($1.target("sets") ?? 0) } }
                func tonnage(_ week: TrainingWeek) -> Double {
                    working(week).reduce(0) { $0 + ($1.target("sets") ?? 0) * ($1.target("reps") ?? 0) * (load($1) ?? 0) }
                }
                if sets(week) >= sets(before) && (tonnage(week) >= tonnage(before) || tonnage(week) == 0) {
                    run.problems.append("\(where_): the deload isn't lighter (\(Int(sets(week))) sets against \(Int(sets(before))))")
                }
            }
            run.weeks.append(week)
            run.history += log(week, index: index, lifter: lifter)
        }
        // Over the program, a lifter who does every set gets stronger: the main lifts' top loads go up.
        if lifter == .author || lifter == .beginner {
            // Hard weeks only: deload and test weeks are light by design.
            let hard = run.weeks.indices.filter { !program[$0].light }.map { run.weeks[$0] }
            let first = hard.prefix(2).flatMap(working).filter(\.main), last = hard.suffix(3).flatMap(working).filter(\.main)
            for exercise in Set(first.map(\.exercise)).intersection(last.map(\.exercise)) {
                let a = first.filter { $0.exercise == exercise }.compactMap(load).max() ?? 0
                let b = last.filter { $0.exercise == exercise }.compactMap(load).max() ?? 0
                if a > 0, b <= a { run.problems.append("\(label): \(names[exercise] ?? exercise) didn't go up (\(Coach.number(a)) → \(Coach.number(b)))") }
            }
        }
        return run
    }

    static let programs: [ReadyProgram?] = ReadyProgram.all.map { $0 } + [nil]

    @Test func dump() {
        guard let slug = ProcessInfo.processInfo.environment["DUMP"] else { return }
        let run = Self.run(ReadyProgram.named(slug), .beginner)
        for (index, week) in run.weeks.enumerated() {
            print("DUMP§ week \(index + 1): " + Self.working(week).filter { $0.exercise == "standing-military-press" || $0.main }
                .map { "\($0.exercise) \(Proposal.dose($0)) \($0.adjustedReason ?? "")" }.joined(separator: " | "))
        }
    }

    @Test(arguments: programs.map { $0?.slug ?? "generator" })
    func clearsTheBar(_ slug: String) {
        let ready = ReadyProgram.named(slug)
        let problems = Lifter.allCases.flatMap { Self.run(ready, $0).problems }
        #expect(problems.isEmpty, Comment(rawValue: problems.prefix(25).joined(separator: "\n")))
    }

    /// For the author to read: four weeks of full-body-3 on their own history. `TEST_RUNNER_WRITE_RUN=1` writes it to
    /// Tests/Evals/code-week-run.md.
    @Test func fourWeeksToRead() throws {
        guard ProcessInfo.processInfo.environment["WRITE_RUN"] == "1" else { return }
        let ready = ReadyProgram.named("full-body-3")
        let run = Self.run(ready, .author)
        var lines = ["# Four code-built weeks (FIT-425): \(ready?.name ?? "") on the author's history", "",
                     "Each week planned from the last, every set logged as planned. Generated by `WeekQualityTests.fourWeeksToRead`.", ""]
        for (index, week) in run.weeks.prefix(4).enumerated() {
            lines.append("## Week \(index + 1)\n")
            for (date, rows) in Dictionary(grouping: Self.working(week), by: \.date).sorted(by: { $0.key < $1.key }) {
                lines.append("**\(date.formatted(.dateTime.weekday(.wide).month().day())), \(rows[0].session)**\n")
                lines += rows.map { "- \(names[$0.exercise] ?? $0.exercise) \(Proposal.dose($0))\($0.adjustedReason.map { " · \($0)" } ?? "")" }
                lines.append("")
            }
        }
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Evals/code-week-run.md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
