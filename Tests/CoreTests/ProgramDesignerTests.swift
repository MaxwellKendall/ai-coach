import Foundation
import Testing
@testable import AICoach

/// FIT-72: what code does around the model: the prompt it's given, and its design turned into planned rows. The
/// model itself is scored in AICoachEvals (ProgramDesignerEvals).
@MainActor
struct ProgramDesignerTests {
    private static let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    private let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))! }

    private func request(age: Int = 36, warmups: Bool = true, history: [LoggedSet] = []) -> ProgramDesigner.Request {
        ProgramDesigner.Request(
            monday: monday,
            settings: TrainingSettings(age: age, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                       equipment: ["barbell", "rack", "dumbbells", "bench", "pull_up_bar"], maxWeeklySets: 60,
                                       warmups: warmups),
            catalog: catalog, names: names, history: history, weeksSinceDeload: 1,
            program: ProgramWeek(phase: .build, kind: .build), programIndex: 4, programWeeks: 12,
            goals: ["Bench Press 225 lb by Dec 1"], calendar: calendar)
    }

    private func item(_ name: String, main: Bool = false, sets: Int = 3, reps: Int? = 8, seconds: Int? = nil,
                      pounds: Int? = nil, rpe: Int? = 7, superset: Int? = nil) -> ProgramDesigner.DesignedWeek.Item {
        .init(name: name, main: main, sets: sets, reps: reps, seconds: seconds, meters: nil, pounds: pounds,
              rpe: rpe, superset: superset)
    }

    @Test func promptCarriesTheWeekAndStaysShort() {
        let history = [LoggedSet(date: monday - 3 * 86_400, exercise: "bench-press", pattern: "push",
                                 measurements: [.init(metric: "load_lb", value: 185, unit: "lb"), .init(metric: "reps", value: 5, unit: "reps"),
                                                .init(metric: "rpe", value: 8, unit: "RPE")])]
        let request = request(history: history)
        let prompt = ProgramDesigner.prompt(request, settings: request.settings, light: false)
        #expect(prompt.contains("Week 5 of 12, build week"))
        #expect(prompt.contains("Goals: Bench Press 225 lb by Dec 1."))
        #expect(prompt.contains("Mon, Wed, Fri"))
        #expect(prompt.contains("Bench Press 185 lb × 5 at RPE 8, 3 days ago"))
        #expect(prompt.contains("Design 3 sessions, each of 4 to 6 exercises and about 18 working sets."))
        #expect(prompt.contains("Squat: Back Squat"))
        // Staples before variations: "Cuban Press, Iron Cross, Anti-Gravity Press" was first.
        #expect(prompt.contains("Vertical push: Arnold Dumbbell Press, Barbell Shoulder Press"))
        let instructions = ProgramDesigner.instructions(request.settings, tier: .of(age: 36), light: false)
        #expect(instructions.contains("RPE at most 8 for main lifts and 7 for the rest"))
        // The on-device model has a 4K-token context; leave most of it for searches and the week.
        #expect((prompt + instructions).count < 4_000)
    }

    @Test func aDesignBecomesRowsOnTheTrainingDays() {
        let request = request()
        let designed = ProgramDesigner.DesignedWeek(sessions: [
            .init(name: "Upper", why: "push and pull", exercises: [item("Bench Press", main: true, reps: 5, pounds: 185, rpe: 8),
                                             item("Dumbbell Row (Single-Arm)", pounds: 60, superset: 1),
                                             item("Plank", reps: nil, seconds: 45, rpe: nil, superset: 1)]),
            .init(name: "Lower", why: "squat", exercises: [item("Back Squat", main: true, reps: 5, pounds: 225)]),
        ])
        let (rows, why) = ProgramDesigner.rows(designed, request, settings: request.settings, tier: .of(age: 36))
        // Upper, Lower, Upper over Monday, Wednesday, Friday.
        #expect(Set(rows.map(\.date)).count == 3)
        #expect(rows.filter { $0.note != TrainingGenerator.warmupNote }.map(\.session) == ["Upper", "Upper", "Upper", "Lower", "Upper", "Upper", "Upper"])
        let bench = rows.first { $0.exercise == "bench-press" && $0.note != TrainingGenerator.warmupNote }
        #expect(bench?.main == true && bench?.target("load_lb") == 185 && bench?.target("reps") == 5 && bench?.target("rpe") == 8)
        // The main lift's warm-up comes first.
        #expect(rows.first?.note == TrainingGenerator.warmupNote && rows.first?.exercise == "bench-press")
        #expect(rows.first { $0.exercise == "dumbbell-row" }?.target("load_lb_hand") == 60)
        let plank = rows.first { $0.exercise == "plank" }
        #expect(plank?.target("duration_s") == 45 && plank?.target("rpe") == nil && plank?.group == 1)
        #expect(why == ["Upper: push and pull", "Lower: squat"])
    }

    @Test func olderTiersGetWarmupsAndTempoOnMainLifts() {
        let request = request(age: 55, warmups: false)
        let designed = ProgramDesigner.DesignedWeek(sessions: [.init(name: "Full", why: "all", exercises: [item("Deadlift", main: true, pounds: 225)])])
        let rows = ProgramDesigner.rows(designed, request, settings: request.settings, tier: .of(age: 55)).workouts
        #expect(rows.filter { $0.note == TrainingGenerator.warmupNote }.count == 3)
        #expect(rows.filter { $0.note == "tempo 3-1-1-1" }.count == 3)
    }

    /// A name the model made up is kept for PlanGuard, which searches for it.
    @Test func unknownNamesAreLeftForTheGuard() {
        let request = request()
        let designed = ProgramDesigner.DesignedWeek(sessions: [.init(name: "Full", why: "all", exercises: [item("Hamstring Curl Deluxe")])])
        let rows = ProgramDesigner.rows(designed, request, settings: request.settings, tier: .of(age: 36)).workouts
        #expect(rows.first?.exercise == "Hamstring Curl Deluxe")
        let guarded = PlanGuard.check(rows, PlanGuard.Context(settings: request.settings, catalog: catalog, names: names,
                                                              history: [], light: false))
        #expect(guarded.workouts.allSatisfy { names[$0.exercise] != nil })
        #expect(guarded.repairs.map(\.rule) == [.exercise, .exercise, .exercise])
    }
}
