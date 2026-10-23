import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

/// Sunday 25 October 2026 starts the week; Monday is the 26th.
private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private let catalog: [Exercise] = (try! Seeder.decode([TemplateSeed].self, "exercises", .main))
    .compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }

private func settings(_ equipment: [String], days: [Int] = [0, 2, 4]) -> TrainingSettings {
    TrainingSettings(age: 0, daysPerWeek: days.count, sessionMinutes: 45, trainingDays: Week.ordered(days),
                     workoutTime: 7 * 60, equipment: Set(equipment), maxWeeklySets: 60)
}

private func program(_ slug: String) -> ReadyProgram { ReadyProgram.named(slug)! }

/// Twelve weeks with the youngest tier's deload every 7th week, as `Profile.program` gives for an unknown age.
private let twelve = ProgramPlan.weeks(count: 12, deloadEvery: 7)

private func logged(_ exercise: String, on day: Date, sets: Int, reps: Double, load: Double? = nil,
                    metric: String = "load_lb") -> [LoggedSet] {
    (0..<sets).map { _ in
        LoggedSet(date: day, exercise: exercise, pattern: nil,
                  measurements: [Measurement(metric: "reps", value: reps, unit: "reps")]
                    + (load.map { [Measurement(metric: metric, value: $0, unit: "lb")] } ?? []))
    }
}

private func week(_ slug: String, _ monday: Date, start: Date = date(10, 25), equipment: [String] = Profile.allEquipment,
                  days: [Int] = [0, 2, 4], history: [LoggedSet] = []) -> TrainingWeek {
    program(slug).week(startingOn: monday, start: start, settings: settings(equipment, days: days), catalog: catalog,
                       history: history, program: twelve, calendar: calendar)
}

private func working(_ week: TrainingWeek, _ exercise: String) -> [PlannedWorkout] {
    week.workouts.filter { $0.exercise == exercise && $0.note != TrainingGenerator.warmupNote }
}

struct ReadyProgramTests {
    /// Every program decodes, and every exercise it names is in the catalog and done with the program's equipment.
    @Test func seedProgramsUseTheCatalog() {
        let slugs = Set(catalog.map(\.slug))
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(ReadyProgram.all.count == 7)
        for ready in ReadyProgram.all {
            #expect(!ready.sessions.isEmpty && !ready.days.isEmpty, "\(ready.slug)")
            let have = Set(ready.equipment + (ready.optional ?? []))
            for item in ready.sessions.flatMap(\.exercises) {
                for slug in item.choices { #expect(slugs.contains(slug), "\(ready.slug): \(slug)") }
                #expect(item.choices.contains { bySlug[$0]?.equipment.isSubset(of: have) == true }, "\(ready.slug): \(item.choices)")
                #expect(item.reps != nil || item.seconds != nil, "\(ready.slug): \(item.choices)")
            }
        }
    }

    @Test func matchesPlaceAndDays() {
        #expect(ReadyProgram.matches(place: .gym, days: 3).first?.slug == "full-body-3")
        #expect(ReadyProgram.matches(place: .gym, days: 2).first?.slug == "full-body-2")
        #expect(ReadyProgram.matches(place: .gym, days: 4).first?.slug == "upper-lower-4")
        #expect(ReadyProgram.matches(place: .gym, days: 6).first?.slug == "push-pull-legs")
        #expect(ReadyProgram.matches(place: .dumbbells, days: 3).first?.slug == "dumbbell-full-body")
        #expect(ReadyProgram.matches(place: .dumbbells, days: 6).first?.slug == "dumbbell-upper-lower")
        // A gym can run every program; dumbbells, the dumbbell and bodyweight ones; no equipment, only bodyweight.
        #expect(ReadyProgram.matches(place: .gym, days: 3).count == 7)
        #expect(Set(ReadyProgram.matches(place: .dumbbells, days: 3).map(\.place)) == [.dumbbells, .bodyweight])
        #expect(ReadyProgram.matches(place: .bodyweight, days: 5).map(\.slug) == ["bodyweight-basics"])
        #expect(program("bodyweight-basics").days(nearest: 5) == 3)
        #expect(program("push-pull-legs").days(nearest: 4) == 3)
    }

    /// Week 1 from a Sunday: A, B, A at the program's starting loads, each saying to find the weight.
    @Test func firstWeekAtStartingLoads() {
        let first = week("full-body-3", date(10, 25))
        #expect(Set(first.workouts.map(\.session)) == ["Day A", "Day B"])
        #expect(first.workouts.filter { $0.exercise == "back-squat" }.map { calendar.component(.day, from: $0.date) } == [26, 30])
        let squat = working(first, "back-squat")[0]
        #expect(squat.target("sets") == 3 && squat.target("reps") == 5 && squat.target("load_lb") == 45)
        #expect(squat.note == ReadyProgram.firstTimeNote && squat.main)
        // The deadlift starts at 95 with a warm-up; a 45 lb bar needs none.
        #expect(week("full-body-3", date(10, 25)).workouts.filter { $0.exercise == "deadlift" }.count == 2)
        #expect(first.workouts.filter { $0.exercise == "bench-press" }.count == 2)
    }

    /// The sessions carry on across weeks: A B A, then B A B.
    @Test func rotationCarriesOn() {
        let second = week("full-body-3", date(11, 1))
        let order = Dictionary(grouping: second.workouts) { calendar.startOfDay(for: $0.date) }.sorted { $0.key < $1.key }
            .map { $0.value[0].session }
        #expect(order == ["Day B", "Day A", "Day B"])
    }

    /// Started on a Thursday with Monday, Wednesday and Friday: Friday only, then week 2 goes on with B.
    @Test func startedMidWeek() {
        let first = week("full-body-3", date(10, 25), start: date(10, 29))
        #expect(Set(first.workouts.map { calendar.component(.day, from: $0.date) }) == [30])
        #expect(Set(first.workouts.map(\.session)) == ["Day A"])
        #expect(week("full-body-3", date(11, 1), start: date(10, 29)).workouts.first?.session == "Day B")
        // Started on a Saturday, with no training day left: a session that day.
        let saturday = week("full-body-3", date(10, 25), start: date(10, 31))
        #expect(Set(saturday.workouts.map { calendar.component(.day, from: $0.date) }) == [31])
    }

    @Test func linearAddsTheStepAndBacksOffAfterTwoMisses() {
        let done = logged("back-squat", on: date(10, 26), sets: 3, reps: 5, load: 100)
            + logged("deadlift", on: date(10, 28), sets: 3, reps: 5, load: 135)
        let next = week("full-body-3", date(11, 1), history: done)
        #expect(working(next, "back-squat").first?.target("load_lb") == 105)
        #expect(working(next, "back-squat").first?.note == nil)
        #expect(working(next, "deadlift").first?.target("load_lb") == 145)

        let missedOnce = logged("back-squat", on: date(10, 26), sets: 3, reps: 4, load: 100)
        #expect(working(week("full-body-3", date(11, 1), history: missedOnce), "back-squat").first?.target("load_lb") == 100)
        let missedTwice = missedOnce + logged("back-squat", on: date(10, 30), sets: 3, reps: 3, load: 100)
        #expect(working(week("full-body-3", date(11, 1), history: missedTwice), "back-squat").first?.target("load_lb") == 90)
    }

    @Test func doubleProgressionAddsRepsThenWeight() {
        let some = logged("split-squat-with-dumbbells", on: date(10, 26), sets: 3, reps: 8, load: 20, metric: "load_lb_hand")
        let split = working(week("dumbbell-full-body", date(11, 1), equipment: ["dumbbells"], history: some), "split-squat-with-dumbbells")[0]
        #expect(split.target("reps") == 9 && split.target("load_lb_hand") == 20)

        let top = logged("split-squat-with-dumbbells", on: date(10, 26), sets: 3, reps: 12, load: 20, metric: "load_lb_hand")
        let heavier = working(week("dumbbell-full-body", date(11, 1), equipment: ["dumbbells"], history: top), "split-squat-with-dumbbells")[0]
        #expect(heavier.target("reps") == 8 && heavier.target("load_lb_hand") == 25)
    }

    /// The push-up ladder moves from incline to floor push-ups at 3 × 10; without a pull-up bar there are no pull-ups.
    @Test func ladderClimbsAndEquipmentDecides() {
        let first = week("bodyweight-basics", date(10, 25), equipment: [])
        #expect(first.workouts.contains { $0.exercise == "incline-push-up" })
        #expect(!first.workouts.contains { $0.exercise.contains("pull-up") || $0.exercise == "chin-up" })
        #expect(!first.workouts.contains { $0.target("load_lb") != nil || $0.target("load_lb_hand") != nil })
        #expect(week("bodyweight-basics", date(10, 25), equipment: ["pull_up_bar"]).workouts.contains { $0.exercise == "scapular-pull-up" })

        let climbed = week("bodyweight-basics", date(11, 1), equipment: [],
                           history: logged("incline-push-up", on: date(10, 26), sets: 3, reps: 10))
        let push = climbed.workouts.filter { $0.exercise.hasSuffix("push-up") }
        #expect(push.map(\.exercise) == ["push-up", "push-up", "push-up"] && push[0].target("reps") == 5)
        // Holds add 5 s.
        let plank = week("bodyweight-basics", date(11, 1), equipment: [],
                         history: [LoggedSet(date: date(10, 26), exercise: "plank", pattern: nil,
                                             measurements: [Measurement(metric: "duration_s", value: 30, unit: "s")])])
        #expect(plank.workouts.first { $0.exercise == "plank" }?.target("duration_s") == 35)
    }

    /// Week 7 is the deload: fewer sets and lighter loads, and week 8 goes on from week 6, not from the deload.
    @Test func deloadWeekIsLighterAndDoesNotCount() {
        let monday6 = date(11, 30), monday7 = date(12, 7), monday8 = date(12, 14)
        #expect(twelve[6].kind == .deload)
        let before = logged("back-squat", on: monday6, sets: 3, reps: 5, load: 150)
        let deload = week("full-body-3", monday7, history: before)
        let squat = working(deload, "back-squat")[0]
        #expect(deload.deload && squat.target("sets") == 2 && squat.target("load_lb") == 135)
        let after = before + logged("back-squat", on: date(12, 8), sets: 2, reps: 5, load: 135)
        #expect(working(week("full-body-3", monday8, history: after), "back-squat").first?.target("load_lb") == 155)
    }

    /// A ready-made program's weeks are its 12, with deloads but no phases or test week, and need no age or weight.
    @Test func profileWeeks() {
        let profile = Profile(age: 0, weightLb: 0)
        #expect(!profile.plansItself)
        profile.programSlug = "full-body-3"
        profile.programStart = date(10, 25)
        profile.targetDate = calendar.date(byAdding: .day, value: 83, to: date(10, 25))
        let weeks = profile.program ?? []
        #expect(weeks.count == 12 && profile.plansItself)
        #expect(Set(weeks.map(\.kind)) == [.base, .deload] && Set(weeks.map(\.phase)) == [.base])
    }
}
