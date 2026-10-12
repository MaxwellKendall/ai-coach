import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-103: each of the coach's tools called as a model would, and what it leaves in the draft. The model is scripted:
/// it calls the tools it's told to, then answers.
@MainActor
struct CoachChatTests {
    private static let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    private let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    /// Monday Oct 12 2026, 6 am.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 6))! }
    private func day(_ offset: Int, hour: Int = 7) -> Date {
        calendar.date(byAdding: DateComponents(day: offset, hour: hour - 6), to: now)!
    }

    private func row(_ exercise: String, _ sets: Double, _ reps: Double, load: Double? = nil, main: Bool = false, on date: Date,
                     session: String) -> PlannedWorkout {
        var targets = [Measurement(metric: "sets", value: sets, unit: "sets"), Measurement(metric: "reps", value: reps, unit: "reps")]
        if let load { targets.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
        return PlannedWorkout(date: date, session: session, exercise: exercise, targets: targets, main: main)
    }

    /// Tuesday upper, Thursday squat day, Saturday more squatting.
    private var week: [PlannedWorkout] {
        [row("bench-press", 4, 5, load: 185, main: true, on: day(1), session: "Upper"),
         row("dumbbell-row", 3, 10, on: day(1), session: "Upper"),
         row("back-squat", 4, 5, load: 225, main: true, on: day(3), session: "Lower"),
         row("dumbbell-romanian-deadlift", 3, 10, on: day(3), session: "Lower"),
         row("goblet-squat", 3, 10, on: day(5), session: "Full")]
    }

    private var context: CoachChat.Context {
        let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 60, trainingDays: [1, 3, 5], workoutTime: 420,
                                        equipment: ["barbell", "rack", "dumbbells", "bench", "pull_up_bar"], maxWeeklySets: 60)
        let start = calendar.date(byAdding: .day, value: -1, to: now)!
        return CoachChat.Context(now: now, settings: settings, catalog: catalog, names: names, history: [], week: week,
                                 goals: ["Bench 225 by Jan 30"], program: ProgramPlan.weeks(count: 16, deloadEvery: 6),
                                 programStart: calendar.startOfDay(for: start), targetDate: calendar.date(byAdding: .day, value: 16 * 7 - 1, to: start),
                                 calendar: calendar)
    }

    /// A model that calls the given tools with the given arguments, then says `reply`.
    struct Scripted: AIModel {
        var calls: [(String, String)]
        var reply = "Done."
        var name: String { "scripted" }
        var isAvailable: Bool { true }
        func session(tools: [any Tool], instructions: String) -> any AISession { Session(tools: tools, calls: calls, reply: reply) }

        struct Session: AISession {
            let tools: [any Tool]
            let calls: [(String, String)]
            let reply: String
            func respond(to prompt: String) async throws -> String {
                var outputs: [String] = []
                for (name, json) in calls {
                    let tool = try #require(tools.first { $0.name == name } as? CoachChat.ChatTool)
                    outputs.append(try await tool.call(arguments: GeneratedContent(json: json)))
                }
                return outputs.isEmpty ? reply : reply + " [" + outputs.joined(separator: " | ") + "]"
            }
            func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
                throw AIFailure.other
            }
        }
    }

    private func turn(_ scope: CoachChat.Scope, _ calls: [(String, String)], draft: CoachChat.Draft = .init(),
                      said: String = "…") async throws -> CoachChat.Reply {
        try await CoachChat.respond(said, scope: scope, context: context, draft: draft, last: nil, model: Scripted(calls: calls))
    }

    /// "30 minutes Wednesday": no session Wednesday, so the model's Thursday is refused (the simulator's on-device
    /// model shortened the wrong day). Saying the day it picked, or no day, goes through.
    @Test func aDayTheyDidntNameIsntChanged() async throws {
        let wrong = try await turn(.week, [("shorten_session", #"{"day": "Thursday", "minutes": 30}"#)], said: "I only have 30 minutes Wednesday")
        #expect(wrong.draft.isEmpty && wrong.text == "There’s no session Wednesday this week. Which one do you mean: Tuesday, Thursday, Saturday?")
        let right = try await turn(.week, [("shorten_session", #"{"day": "Thursday", "minutes": 30}"#)], said: "only 30 min thurs")
        #expect(!right.draft.isEmpty)
        // Monday the 12th: tomorrow is Tuesday.
        let tomorrow = try await turn(.week, [("move_session", #"{"day": "Tuesday", "to": "Wednesday"}"#)], said: "move tomorrow to the day after")
        #expect(!tomorrow.draft.isEmpty)
    }

    // MARK: This week

    @Test func aSessionMovesToAnotherDayAtItsTime() async throws {
        let reply = try await turn(.week, [("move_session", #"{"day": "Tuesday", "to": "Wednesday"}"#)])
        let moved = try #require(reply.draft.week).filter { $0.exercise == "bench-press" }
        #expect(moved.count == 1 && calendar.isDate(moved[0].date, inSameDayAs: day(2)))
        #expect(calendar.component(.hour, from: moved[0].date) == 7)
        #expect(reply.draft.lines == ["Tuesday’s session moves to Wednesday."])
    }

    /// Thursday's squats to Friday sit within 48 hours of Saturday's: refused, nothing changes.
    @Test func aMoveThatCrowdsAMovementIsRefused() async throws {
        let reply = try await turn(.week, [("move_session", #"{"day": "Thursday", "to": "Friday"}"#)])
        #expect(reply.draft.isEmpty && reply.draft.week == nil)
        #expect(reply.text.contains("48 hours"))
    }

    @Test func aShorterSessionLosesAccessorySetsFirst() async throws {
        let reply = try await turn(.week, [("shorten_session", #"{"day": "Thursday", "minutes": 30}"#)])
        let thursday = try #require(reply.draft.week).filter { calendar.isDate($0.date, inSameDayAs: day(3)) && $0.note != TrainingGenerator.warmupNote }
        let before = week.filter { calendar.isDate($0.date, inSameDayAs: day(3)) }.reduce(0) { $0 + ($1.target("sets") ?? 0) }
        #expect(thursday.reduce(0) { $0 + ($1.target("sets") ?? 0) } < before)
        #expect(thursday.contains { $0.exercise == "back-squat" })
        #expect(reply.draft.lines == ["Thursday fits into 30 minutes."])
    }

    @Test func aSkippedDayIsGoneAndChangesAddUp() async throws {
        let first = try await turn(.week, [("skip_day", #"{"day": "Saturday"}"#)])
        let second = try await turn(.week, [("lighter_day", #"{"day": "Tuesday"}"#)], draft: first.draft)
        let rows = try #require(second.draft.week)
        #expect(!rows.contains { calendar.isDate($0.date, inSameDayAs: day(5)) })
        #expect(second.draft.lines.count == 2)
    }

    @Test func anExerciseIsSwappedInEverySession() async throws {
        let reply = try await turn(.week, [("swap_everywhere", #"{"exercise": "Bench Press", "replacement": "Dumbbell Bench Press"}"#)])
        let rows = try #require(reply.draft.week)
        #expect(!rows.contains { $0.exercise == "bench-press" })
        #expect(rows.contains { $0.exercise == "dumbbell-bench-press" && $0.main })
    }

    @Test func anExerciseTheyCantDoIsntSwappedIn() async throws {
        let reply = try await turn(.week, [("swap_everywhere", #"{"exercise": "Bench Press", "replacement": "Seated Cable Rows"}"#)])
        #expect(reply.draft.isEmpty)
    }

    // MARK: The program

    @Test func programChangesWaitInTheDraft() async throws {
        let reply = try await turn(.program, [
            ("set_training_days", #"{"days": ["Monday", "Wednesday", "Friday", "Saturday"]}"#),
            ("set_session_length", #"{"minutes": "45"}"#),
            ("add_trip", #"{"first_day": "2026-11-09", "last_day": "2026-11-20"}"#),
        ])
        #expect(reply.draft.trainingDays == [0, 2, 4, 5])
        #expect(reply.draft.sessionMinutes == 45)
        #expect(reply.draft.travelWeeks?.isEmpty == false)
        #expect(reply.draft.lines.count == 3)
    }

    @Test func aTargetDateOutsideTheProgramsRangeIsRefused() async throws {
        let ok = try await turn(.program, [("set_target_date", #"{"date": "2027-03-01"}"#)])
        #expect(ok.draft.targetDate != nil)
        let tooFar = try await turn(.program, [("set_target_date", #"{"date": "2029-01-01"}"#)])
        #expect(tooFar.draft.targetDate == nil && tooFar.draft.isEmpty)
    }

    /// A question gets words and no tools: the draft stays as it was.
    @Test func aQuestionChangesNothing() async throws {
        let reply = try await CoachChat.respond("Why squats Thursday?", scope: .week, context: context, draft: .init(), last: nil,
                                                model: Scripted(calls: [], reply: "To keep 48 hours between squat days."))
        #expect(reply.draft.isEmpty && reply.text == "To keep 48 hours between squat days.")
    }

    @Test func theModelIsToldTheWeekTheDraftAndTheLastTurn() {
        var draft = CoachChat.Draft()
        draft.lines = ["No session Saturday."]
        let text = CoachChat.instructions(.week, context: context, draft: draft,
                                          last: CoachChat.Turn(said: "skip saturday", reply: "Done, Saturday's off."))
        #expect(text.contains("Tuesday Upper: Bench Press"))
        #expect(text.contains("No session Saturday."))
        #expect(text.contains("skip saturday"))
        #expect(text.contains("Bench 225 by Jan 30"))
    }
}
