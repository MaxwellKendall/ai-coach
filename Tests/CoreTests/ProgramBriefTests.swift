import Foundation
import Testing
@testable import AICoach

/// FIT-95: what code does around the program brief: the prompt, the checks on what the model wrote, when it's
/// written again, and how each week is told where its goals should be.
@MainActor
struct ProgramBriefTests {
    private static let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    private let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })
    private let weeks = ProgramPlan.weeks(count: 12, deloadEvery: 6)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))! }
    private let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                            equipment: ["barbell", "rack", "dumbbells", "bench", "pull_up_bar"], maxWeeklySets: 60)
    private let bench = GoalLift(exercise: "bench-press", measure: "1rm_lb", start: 190, target: 225, deadline: nil)

    private var request: ProgramBrief.Request {
        ProgramBrief.Request(settings: settings, catalog: catalog, names: names, goals: ["Bench more 225 lb by Jan 9"],
                             goalLifts: [bench], weeks: weeks)
    }

    private func phase(_ phase: String, lifts: [String], reps: Int = 5) -> ProgramBrief.Phase {
        ProgramBrief.Phase(phase: phase, focus: "\(phase) work", mainLifts: lifts, mainReps: reps, accessoryReps: 10)
    }

    @Test func theTopSetForAnEstimatedMaxIsBrzyckiTheOtherWay() {
        #expect(ProgramPlan.load(forMax: 225, reps: 5) == 200)
        #expect(ProgramPlan.load(forMax: 200, reps: 3) == 190)
        #expect(ProgramPlan.estimatedMax(load: ProgramPlan.load(forMax: 225, reps: 5), reps: 5) == 225)
    }

    @Test func thePromptGivesTheGoalLiftsTheProgramsShapeAndAMenuWithTheGoalLiftOnIt() {
        let prompt = ProgramBrief.prompt(request)
        #expect(prompt.contains("Goal lifts: Bench Press (estimated max 190 lb now, 225 at the end)."))
        #expect(prompt.contains("Program: 12 weeks. Weeks 1–"))
        #expect(prompt.contains("Week 12 a test week."))
        #expect(prompt.contains("Horizontal push: Bench Press") || prompt.contains("Horizontal push: ") && prompt.contains("Bench Press"))
        #expect(prompt.contains("Plan these phases: base, build, peak."))
        // The on-device model has a 4K-token context.
        #expect((ProgramBrief.instructions + prompt).count < 3_000)
    }

    @Test func checkingKeepsTheProgramsPhasesInOrderAndOnlyLiftsTheCatalogHas() {
        let written = ProgramBrief(phases: [phase("peak", lifts: ["Bench Press", "Back Squat"], reps: 3),
                                            phase("base", lifts: ["bench press", "Moon Press", "Back Squat", "Back Squat"]),
                                            phase("build", lifts: ["Bench Press"])])
        let checked = ProgramBrief.checked(written, request)
        #expect(checked.phases.map(\.phase) == ["base", "build", "peak"])
        // Names resolve to the catalog's own; unknown ones and repeats go.
        #expect(checked.phases[0].mainLifts == ["Bench Press", "Back Squat"])
        // A program without a peak has no peak line.
        let short = ProgramBrief.checked(written, ProgramBrief.Request(settings: settings, catalog: catalog, names: names, goals: [],
                                                                       goalLifts: [], weeks: Array(weeks.prefix(3))))
        #expect(short.phases.map(\.phase) == ["base"])
    }

    @Test func theKeyChangesWithGoalsDaysAndEquipmentButNotGoalOrder() {
        let key = ProgramBrief.key(goals: ["A", "B"], settings: settings, weeks: weeks)
        #expect(key == ProgramBrief.key(goals: ["B", "A"], settings: settings, weeks: weeks))
        #expect(key != ProgramBrief.key(goals: ["A", "C"], settings: settings, weeks: weeks))
        var fewer = settings
        fewer.trainingDays = [0, 3]
        fewer.daysPerWeek = 2
        #expect(key != ProgramBrief.key(goals: ["A", "B"], settings: fewer, weeks: weeks))
        var home = settings
        home.equipment = ["dumbbells"]
        #expect(key != ProgramBrief.key(goals: ["A", "B"], settings: home, weeks: weeks))
    }

    @Test func aWeekIsToldItsPhaseOfTheBriefAndWhereEachGoalShouldBe() {
        var request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: catalog, names: names, history: [], weeksSinceDeload: 1,
            program: weeks[4], programIndex: 4, programWeeks: 12, goals: ["Bench more 225 lb by Jan 9"],
            brief: phase("build", lifts: ["Bench Press", "Back Squat"]), goalLifts: [bench], programPlan: weeks, calendar: calendar)
        let aim = ProgramPlan.expected(from: 190, target: 225, at: 4, weeks: weeks).rounded()
        var prompt = ProgramDesigner.prompt(request, settings: settings, light: false)
        #expect(prompt.contains("This phase's plan: build work. Main lifts: Bench Press, Back Squat, around 5 reps; the rest around 10."))
        #expect(prompt.contains("Bench Press is a goal (225 lb): estimated max about 190 now; aim for about \(Coach.number(aim)) by the end of this week, "
                                + "a top set near \(Coach.number(ProgramPlan.load(forMax: aim, reps: 5))) × 5."))
        // The brief's reps stand for the style's.
        #expect(!prompt.contains("main lifts around 8 reps"))
        // The aim reads the lift's recent best as where it is now.
        request.history = [LoggedSet(date: monday - 2 * 86_400, exercise: "bench-press", pattern: "push",
                                     measurements: [.init(metric: "load_lb", value: 180, unit: "lb"), .init(metric: "reps", value: 5, unit: "reps")])]
        prompt = ProgramDesigner.prompt(request, settings: settings, light: false)
        #expect(prompt.contains("estimated max about 203 now"))
        // Deloads hold; they aren't told to reach for a goal.
        #expect(!ProgramDesigner.prompt(request, settings: settings, light: true).contains("aim for about"))
        let instructions = ProgramDesigner.instructions(settings, tier: .of(age: 36), light: false)
        #expect((prompt + instructions).count < 4_000)
    }

    @Test func goalLiftsAreTheMaxAndRepsGoalsFromWhereTheyStarted() {
        let goals = [Goal(kind: .training, metric: "bench-press.1rm_lb", target: 225, unit: "lb"),
                     Goal(kind: .training, metric: "pull-up.reps", target: 15, unit: "reps"),
                     Goal(kind: .body, metric: "weight_lb", target: 180, unit: "lb")]
        goals[0].baseline = 190
        let history = [LoggedSet(date: monday, exercise: "pull-up", pattern: "pull", measurements: [.init(metric: "reps", value: 8, unit: "reps")])]
        let lifts = Planner.goalLifts(goals, history: history)
        #expect(lifts == [GoalLift(exercise: "bench-press", measure: "1rm_lb", start: 190, target: 225, deadline: nil),
                          GoalLift(exercise: "pull-up", measure: "reps", start: 8, target: 15, deadline: nil)])
    }
}
