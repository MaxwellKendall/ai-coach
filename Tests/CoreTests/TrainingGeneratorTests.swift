import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// fitness-planner config.yaml, inline. The composite case below is session-logs/2026-07-10.html.
private let config = TrainingSettings(
    age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 7 * 60,
    equipment: ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"], maxWeeklySets: 60,
    style: .powerbuilding, warmups: true, deloadEveryWeeks: 6)

private func exercise(_ slug: String, _ pattern: String, equipment: [String] = [], muscles: [String] = [],
                      tags: [String] = [], fatigue: Int = 2) -> Exercise {
    Exercise(slug: slug, attributes: [
        TemplateAttribute(key: "movement_pattern", values: [pattern]),
        TemplateAttribute(key: "equipment", values: equipment),
        TemplateAttribute(key: "muscles_primary", values: muscles),
        TemplateAttribute(key: "tags", values: tags),
        TemplateAttribute(key: "fatigue_cost", values: [String(fatigue)]),
    ])!
}

private func logged(_ exercise: String, _ pattern: String, _ month: Int, _ day: Int,
                    _ measurements: [(String, Double)] = []) -> LoggedSet {
    LoggedSet(date: date(month, day), exercise: exercise, pattern: pattern,
              measurements: measurements.map { Measurement(metric: $0.0, value: $0.1, unit: "") })
}

struct TrainingGeneratorTests {
    @Test(arguments: [(25, "18–29", 9.0, false), (36, "30–39", 8, false), (40, "40–49", 7, true),
                      (55, "50–59", 7, true), (70, "60+", 6, true)])
    func ageTier(age: Int, name: String, topRPE: Double, mandatoryWarmup: Bool) {
        let tier = AgeTier.of(age: age)
        #expect(tier.name == name)
        #expect(tier.topRPE == topRPE)
        #expect(tier.mandatoryWarmup == mandatoryWarmup)
    }

    @Test func tierDefaults() {
        #expect(AgeTier.of(age: 55).tempo == "3-1-1-1")
        #expect(AgeTier.of(age: 36).deloadEveryWeeks == 6)
        #expect(AgeTier.of(age: 45).deloadEveryWeeks == 5)
    }

    @Test(arguments: [(2, 45, Split.fullBody, 14...18), (2, 60, .fullBody, 20...24), (3, 45, .fullBody, 14...18),
                      (3, 60, .fullBody, 18...22), (4, 45, .upperLower, 14...18), (4, 60, .upperLower, 18...22),
                      (5, 50, .pushPullLegs, 16...22)])
    func volumeMapping(days: Int, minutes: Int, split: Split, sets: ClosedRange<Int>) {
        #expect(VolumePlan.of(daysPerWeek: days, sessionMinutes: minutes) == VolumePlan(split: split, setsPerSession: sets))
    }

    @Test func squatAndDeadliftAreNeverBothMainLifts() {
        for split in [Split.fullBody, .upperLower, .pushPullLegs] {
            for session in split.rotation {
                let mains = Set(session.slots.filter(\.main).map(\.pattern))
                #expect(!mains.isSuperset(of: ["squat", "hinge"]), "\(split) \(session.name)")
            }
        }
    }

    @Test func filtersEquipmentAvoidListAndInjuries() {
        var settings = config
        settings.equipment = ["dumbbells"]
        settings.avoidExercises = ["plank"]
        settings.injuredAreas = ["shoulders"]
        #expect(!TrainingGenerator.allows(exercise("back-squat", "squat", equipment: ["barbell", "rack"]), settings))
        #expect(TrainingGenerator.allows(exercise("goblet-squat", "squat", equipment: ["dumbbells"]), settings))
        #expect(TrainingGenerator.allows(exercise("push-up", "push"), settings)) // bodyweight needs nothing
        #expect(!TrainingGenerator.allows(exercise("plank", "core"), settings))
        #expect(!TrainingGenerator.allows(exercise("press", "push", muscles: ["shoulders"]), settings))
    }

    @Test func mainSlotTakesTheHeaviestGoalLiftAccessoryAvoidsRecentWork() {
        let catalog = [exercise("push-up", "push", tags: ["goal_lift"], fatigue: 2),
                       exercise("bench-press", "push", tags: ["goal_lift"], fatigue: 4),
                       exercise("db-press", "push", fatigue: 3),
                       exercise("plank", "core"), exercise("dead-bug", "core")]
        let main = TrainingGenerator.pick(Slot(pattern: "push", main: true), from: catalog, excluding: [],
                                          recent: ["bench-press"])
        #expect(main?.slug == "bench-press")
        let accessory = TrainingGenerator.pick(Slot(pattern: "push", main: false), from: catalog, excluding: ["bench-press"],
                                               recent: [])
        #expect(accessory?.slug == "db-press")
        let core = TrainingGenerator.pick(Slot(pattern: "core", main: false), from: catalog, excluding: [], recent: ["plank"])
        #expect(core?.slug == "dead-bug")
    }

    @Test func recentExercisesAreTheLastTwoSessions() {
        let history = [logged("a", "squat", 6, 1), logged("b", "push", 6, 3), logged("c", "pull", 6, 5),
                       logged("d", "core", 6, 5)]
        #expect(TrainingGenerator.recentExercises(history, sessions: 2, calendar: calendar) == ["b", "c", "d"])
    }

    @Test func patternWithNoSetsIn28DaysIsUndertrained() {
        let history = [logged("squat", "squat", 6, 20), logged("carry", "carry", 5, 1),
                       logged("bench", "push", 6, 1), logged("row", "pull", 6, 1), logged("dl", "hinge", 6, 1),
                       logged("plank", "core", 6, 1)]
        #expect(TrainingGenerator.undertrainedPatterns(history, before: date(6, 22), calendar: calendar) == ["carry"])
    }

    @Test func rotationContinuesWithTheStalestSession() {
        let rotation = Split.fullBody.rotation
        #expect(TrainingGenerator.rotationStart(rotation, history: []) == 0)
        let lastWasA = [logged("bench", "push", 7, 8), logged("squat", "squat", 7, 10), logged("pull-up", "pull", 7, 10)]
        #expect(rotation[TrainingGenerator.rotationStart(rotation, history: lastWasA)].name == "Session B")
    }

    @Test func setsFitTheVolumeRange() {
        // Too few: main lifts grow first.
        #expect(TrainingGenerator.fit([(true, 3), (false, 3), (false, 3), (false, 3)], to: 14...18) == [5, 3, 3, 3])
        // Too many: accessories shrink first.
        #expect(TrainingGenerator.fit([(true, 4), (false, 6), (false, 6), (false, 4)], to: 14...18) == [4, 5, 5, 4])
        #expect(TrainingGenerator.fit([(true, 3), (false, 3), (false, 3), (false, 3), (false, 3)], to: 14...18)
            == [3, 3, 3, 3, 3])
    }

    @Test(arguments: [
        (165.0, 7.0, true, false, 170.0),  // at least 1 under the cap: +5
        (165, 8, true, false, 165),        // at the cap: hold
        (95, 6, false, false, 95),         // accessories hold
        (165, 7, true, true, 145),         // deload: −13%, nearest 5
        (220, 7, true, true, 190),
    ])
    func loadProgression(load: Double, rpe: Double, main: Bool, deload: Bool, expected: Double) {
        #expect(TrainingGenerator.nextLoad(load, lastRPE: rpe, main: main, tier: AgeTier.of(age: 36), deload: deload)
            == expected)
    }

    @Test func emptyHistoryStillPlansAWeekWithoutLoads() {
        let catalog = [exercise("back-squat", "squat", equipment: ["barbell", "rack"], tags: ["goal_lift"]),
                       exercise("bench-press", "push", equipment: ["barbell", "bench"], tags: ["goal_lift"]),
                       exercise("deadlift", "hinge", equipment: ["barbell"], tags: ["goal_lift"]),
                       exercise("pull-up", "pull", equipment: ["pull_up_bar"], tags: ["goal_lift"]),
                       exercise("dumbbell-row", "pull", equipment: ["dumbbells"]),
                       exercise("push-up", "push", tags: ["goal_lift"]),
                       exercise("farmer-carry", "carry", equipment: ["dumbbells"]),
                       exercise("plank", "core", tags: ["isometric"])]
        let week = TrainingGenerator.week(startingOn: date(7, 20, hour: 0), settings: config, catalog: catalog,
                                          history: [], weeksSinceDeload: 0, calendar: calendar)
        #expect(Set(week.workouts.map { calendar.component(.weekday, from: $0.date) }) == [2, 4, 6]) // Mon, Wed, Fri
        #expect(week.workouts.first?.date == date(7, 20, hour: 7))
        #expect(week.workouts.allSatisfy { $0.target("load_lb") == nil })
        #expect(!week.workouts.contains { $0.note == TrainingGenerator.warmupNote }) // no load, no warm-up
        // Nothing logged, so every pattern is undertrained and gets 4 sets before fitting.
        #expect(week.workouts.filter { $0.session == "Session A" }.allSatisfy { $0.target("sets")! >= 3 })
        #expect(week.workouts.first { $0.exercise == "plank" }?.target("duration_s") == 45)
        #expect(week.workouts.first { $0.exercise == "farmer-carry" }?.target("distance_m") == 30)
    }

    @Test func overTheWeeklyCeilingIsFlaggedNotTrimmed() {
        var settings = config
        settings.maxWeeklySets = 20
        let catalog = [exercise("back-squat", "squat"), exercise("bench", "push"), exercise("row", "pull"),
                       exercise("dl", "hinge"), exercise("carry", "carry"), exercise("plank", "core")]
        let week = TrainingGenerator.week(startingOn: date(7, 20, hour: 0), settings: settings, catalog: catalog,
                                          history: [], weeksSinceDeload: 0, calendar: calendar)
        #expect(week.totalSets > 20)
        #expect(week.warnings.contains { $0.contains("20-set weekly ceiling") })
    }

    @Test func olderTiersGetWarmupsAndTempoEvenWhenWarmupsAreOff() {
        var settings = config
        settings.age = 55
        settings.warmups = false
        let catalog = [exercise("back-squat", "squat", tags: ["goal_lift"]), exercise("plank", "core")]
        let history = [logged("back-squat", "squat", 7, 10, [("load_lb", 135), ("reps", 5), ("rpe", 6)])]
        let week = TrainingGenerator.week(startingOn: date(7, 20, hour: 0), settings: settings, catalog: catalog,
                                          history: history, weeksSinceDeload: 0, calendar: calendar)
        let squats = week.workouts.filter { $0.exercise == "back-squat" }
        #expect(squats.first?.note == TrainingGenerator.warmupNote)
        #expect(squats.last?.target("load_lb") == 140) // RPE 6 under a 7 cap: +5
        #expect(squats.first?.target("load_lb") == 85) // 60% of 140, nearest 5
        #expect(squats.last?.note == "tempo 3-1-1-1")
        #expect(squats.last?.target("rpe") == 7)
    }

    @Test(arguments: [(7.0, 3.0, 4.0, 1.0, 1.95), (2, 1, 1, 0.2, 0.5), (2, 1, 1, 0, 0.4)])
    func compositeScore(effort: Double, energy: Double, form: Double, completion: Double, expected: Double) {
        #expect(abs(Training.composite(effort: effort, energy: energy, form: form, completion: completion) - expected) < 0.0001)
    }
}

/// FIT-2 acceptance: the real history and config produce the week fitness-planner actually planned
/// (plans/2026-07-20.html: a deload, ~13% off the last loads, 2 working sets, RPE ≤ 6).
@MainActor
struct TrainingGeneratorAcceptanceTests {
    private func inputs() throws -> (catalog: [Exercise], history: [LoggedSet]) {
        let seeds = try Seeder.decode([TemplateSeed].self, "exercises", .main)
        let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
        let patterns = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.pattern) })
        let history = try Seeder.decode([LogSeed].self, "history", .main)
            .filter { $0.kind == .workout }
            .map { LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: patterns[$0.template ?? ""],
                             measurements: $0.measurements) }
        return (catalog, history)
    }

    @Test func deloadWeekMatchesTheRealPlan() throws {
        let (catalog, history) = try inputs()
        let monday = Week.monday(of: date(7, 20), calendar: calendar)
        // profile.json (2026-07-12): 8 weeks since the last deload, against a 6-week setting.
        let week = TrainingGenerator.week(startingOn: monday, settings: config, catalog: catalog, history: history,
                                          weeksSinceDeload: 8, calendar: calendar)
        #expect(week.deload)
        // The last session (Jul 10) was A, so the week runs B/A/B.
        #expect(week.workouts.map(\.session).uniqued() == ["Session B", "Session A"])
        func working(_ slug: String) -> PlannedWorkout? {
            week.workouts.first { $0.exercise == slug && $0.note != TrainingGenerator.warmupNote }
        }
        #expect(working("back-squat")?.target("load_lb") == 145)
        #expect(working("bench-press")?.target("load_lb") == 135)
        #expect(working("deadlift")?.target("load_lb") == 190)
        #expect(working("back-squat")?.target("sets") == 2)
        #expect(week.workouts.compactMap { $0.target("rpe") }.allSatisfy { $0 <= 6 })
        #expect(week.totalSets < 42) // well under the 42–54 normal week
    }

    @Test func normalWeekProgressesAndFitsTheVolumeTable() throws {
        let (catalog, history) = try inputs()
        let monday = Week.monday(of: date(7, 20), calendar: calendar)
        let week = TrainingGenerator.week(startingOn: monday, settings: config, catalog: catalog, history: history,
                                          weeksSinceDeload: 0, calendar: calendar)
        #expect(!week.deload)
        #expect(week.warnings.isEmpty)
        #expect((42...54).contains(week.totalSets))
        // Last logged at RPE 7 under an 8 cap: +5 lb.
        let squat = week.workouts.first { $0.exercise == "back-squat" && $0.note == nil }
        #expect(squat?.target("load_lb") == 170)
        #expect(squat?.target("reps") == 5)
        #expect(week.workouts.first { $0.exercise == "dumbbell-row" }?.target("reps") == 10)
        // Every session's working sets are in the 14–18 range.
        for session in Dictionary(grouping: week.workouts.filter { $0.note != TrainingGenerator.warmupNote }, by: \.date).values {
            #expect((14...18).contains(session.reduce(0) { $0 + Int($1.target("sets")!) }))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
