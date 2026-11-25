#if DEBUG
import Foundation
import FoundationModels
import SwiftData
import Synchronization

/// FIT-445: `-uiTesting YES -role coach|client|solo|soloPro` opens the app as that role, the same on every launch, for
/// RoleUITests and screenshots: a new in-memory store, no defaults from an earlier run, and signed out, so nothing
/// reaches the server. Each role is the debug switches that already exist: coach is `-sampleClients`, client is
/// `-coach Sam` with a session of Sam's today, solo is a ready program started today, soloPro is solo with `-pro`.
/// `-noProgram YES` leaves solo without a program. new is a first launch, on Welcome. Other launch arguments still win, so `-role client -sampleClients
/// YES` is a client with a sample roster.
enum DebugRole {
    static var uiTesting: Bool { UserDefaults.standard.bool(forKey: "uiTesting") }
    /// Let a UI test supply its own goals through sync units without loading the dogfood goals.
    static var skipSeedGoals: Bool { uiTesting && UserDefaults.standard.bool(forKey: "skipSeedGoals") }
    /// FIT-446: `-demo YES` is the App Review demo: no debug rows or banners, and already signed in as a local demo
    /// account (`Account.demo`), so a purchase goes straight to StoreKit. Nothing reaches the server: `Cloud.run` and
    /// `SyncEngine` refuse in it. Works alongside `-uiTesting YES -role …`.
    static var demo: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var role: String? { uiTesting ? UserDefaults.standard.string(forKey: "role") : nil }
    static var workoutMotionFixture: Bool { uiTesting && UserDefaults.standard.bool(forKey: "workoutMotionFixture") }
    static var workoutReduceMotion: Bool { UserDefaults.standard.bool(forKey: "workoutReduceMotion") }
    static var workoutGoalHitFixture: Bool { uiTesting && UserDefaults.standard.bool(forKey: "workoutGoalHit") }
    static var workoutMultiWinFixture: Bool { uiTesting && UserDefaults.standard.bool(forKey: "workoutMultiWin") }
    static var workoutSupersetFixture: Bool { uiTesting && UserDefaults.standard.bool(forKey: "workoutSuperset") }
    static var programDoneFixture: Bool { uiTesting && UserDefaults.standard.bool(forKey: "programDoneFixture") }

    /// FIT-426: `-aiWeeks YES` designs a Pro lifter's weeks with `StubDesigner`, so a UI test sees an AI week without
    /// a network or a model; without it, a UI test's weeks stay code planned.
    static var aiWeeks: Bool { uiTesting && UserDefaults.standard.bool(forKey: "aiWeeks") }
    /// FIT-426: every `StubDesigner` answer this launch, so a UI test can prove a free lifter never reached a model.
    @MainActor static var modelCalls = 0

    /// Before anything reads the defaults or the saved roster.
    @MainActor static func prepare() {
        if demo { UserDefaults.standard.removeObject(forKey: "pro") }
        guard uiTesting else { return }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        try? FileManager.default.removeItem(at: Roster.savedURL)
        var defaults: [String: Any] = ["welcomed": true]
        switch role {
        case "coach": defaults["sampleClients"] = true
        case "client": defaults["coach"] = "Sam"
        case "soloPro": defaults["pro"] = true
        // FIT-454: a first launch, on Welcome, with nothing set up.
        case "new": defaults["welcomed"] = false
        default: break
        }
        // The registration domain, under the launch arguments.
        UserDefaults.standard.register(defaults: defaults)
    }

    @MainActor static func seed(_ context: ModelContext, now: Date = .now) throws {
        switch role {
        case "client":
            // A session Sam wrote for today, as the server would sync it (FIT-202).
            let at = Calendar.current.startOfDay(for: now).timeIntervalSince1970 + 18 * 3600
            let lifts: [(String, Double)] = workoutMotionFixture ? [("back-squat", 185)] : [("back-squat", 185), ("bench-press", 135)]
            if workoutMotionFixture {
                let profile = Profile(age: 34, weightLb: 180)
                profile.programStart = Calendar.current.startOfDay(for: now)
                profile.targetDate = Calendar.current.date(byAdding: .day, value: 28, to: now)
                context.insert(profile)
                let target: Double = workoutGoalHitFixture ? 200 : 500
                let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: target, unit: "lb")
                goal.baseline = UserDefaults.standard.bool(forKey: "workoutNoBest") ? 400 : (workoutGoalHitFixture ? 150 : 200)
                context.insert(goal)
                if workoutMultiWinFixture {
                    let benchGoal = Goal(kind: .training, metric: "bench-press.1rm_lb", target: 250, unit: "lb")
                    benchGoal.baseline = 135
                    context.insert(benchGoal)
                }
            }
            var rows: [[String: Any]] = lifts.enumerated().map { index, lift in
                ["id": UUID().uuidString, "kind": "workout", "at": at + Double(index), "slot": "Lower A", "template": lift.0,
                 "targets": [["metric": "sets", "value": workoutMotionFixture ? 2 : 3, "unit": "sets"], ["metric": "reps", "value": 5, "unit": "reps"],
                             ["metric": "load_lb", "value": lift.1, "unit": "lb"]],
                 "note": workoutMotionFixture ? "Brace, then sit between your heels." : "", "main": index == 0, "pinned": true]
            }
            if workoutSupersetFixture || workoutMultiWinFixture {
                rows.append(["id": UUID().uuidString, "kind": "workout", "at": at + 10, "slot": "Lower A", "template": "bench-press",
                             "targets": [["metric": "sets", "value": 1, "unit": "sets"], ["metric": "reps", "value": 8, "unit": "reps"],
                                         ["metric": "load_lb", "value": 155, "unit": "lb"]],
                             "note": "Row between bench sets.", "main": true, "pinned": true, "group": 1])
                rows.append(["id": UUID().uuidString, "kind": "workout", "at": at + 11, "slot": "Lower A", "template": "bent-over-barbell-row",
                             "targets": [["metric": "sets", "value": 1, "unit": "sets"], ["metric": "reps", "value": 8, "unit": "reps"],
                                         ["metric": "load_lb", "value": 115, "unit": "lb"]],
                             "note": "", "main": false, "pinned": true, "group": 1])
            }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
            try SyncUnits.apply("plan#\(SyncUnits.day(now))", body: body, in: context)
            try context.save()
        case "solo", "soloPro":
            guard !UserDefaults.standard.bool(forKey: "noProgram"),
                  let program = ReadyProgram.all.first(where: { $0.slug == "full-body-3" }) ?? ReadyProgram.all.first else { return }
            let profile = Profile(age: 34, weightLb: 180)
            context.insert(profile)
            // Today (0 = Monday) and every other day after it, so Today has a session.
            let today = (Calendar.current.component(.weekday, from: now) + 5) % 7
            let days = (0..<program.days(nearest: 3)).map { (today + 2 * $0) % 7 }
            try Planner.start(program, days: days, equipment: Profile.allEquipment, profile: profile, in: context, now: now)
            if programDoneFixture {
                // Backdate the program past its final week and seed completed sessions + PRs so ProgramDoneCard plays in full.
                let finishedStart = Calendar.current.date(byAdding: .weekOfYear, value: -(program.weeks + 1), to: now)!
                profile.programStart = Calendar.current.startOfDay(for: finishedStart)
                profile.targetDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now)
                let templates = (try? context.fetch(FetchDescriptor<Template>())) ?? []
                let squatId = templates.first { $0.slug == "back-squat" }?.id
                let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225, unit: "lb")
                goal.baseline = 165
                context.insert(goal)
                for week in 0..<program.weeks {
                    for offset in [0, 2, 4] {
                        if let day = Calendar.current.date(byAdding: .day, value: week * 7 + offset, to: finishedStart) {
                            let load = 165.0 + Double(week) * 5.0
                            context.insert(LogEntry(kind: .workout, timestamp: day, templateRef: squatId, measurements: [
                                Measurement(metric: "reps", value: 5, unit: "reps"),
                                Measurement(metric: "load_lb", value: load, unit: "lb"),
                            ]))
                        }
                    }
                }
                try context.save()
            }
        default:
            break
        }
    }
}

/// FIT-426: a designer for UI tests: no network and no model. It answers the week's design with the program's own
/// sessions for it, and a reason on each day's first main lift (a fixed one for a squat or a bench). Any other ask fails, as
/// a model that can't answer would, except first loads, which are 45 lb each.
struct StubDesigner: AIModel {
    static let changes = (squat: "Squat up 5 lb: all sets done Monday", bench: "Bench held at 135: two sets short last week")

    /// The week's sessions as the code plans them, as `DesignedWeek` JSON.
    let week: JSON
    let calls = Calls()

    final class Calls: Sendable {
        let count = Mutex(0)
    }

    var name: String { "stub" }
    var isAvailable: Bool { true }

    /// The stub for a week, from the program's sessions for it.
    @MainActor static func week(of date: Date, in context: ModelContext) -> StubDesigner {
        let templates = (try? context.fetch(FetchDescriptor<Template>())) ?? []
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        return StubDesigner(outline: (try? Planner.preview(weekOf: date, in: context)) ?? [], names: names)
    }

    init(outline: [PlannedWorkout], names: [String: String]) {
        var days: [(date: Date, name: String, rows: [PlannedWorkout])] = []
        for row in outline where row.note != TrainingGenerator.warmupNote {
            if let index = days.firstIndex(where: { $0.date == row.date }) { days[index].rows.append(row) }
            else { days.append((row.date, row.session, [row])) }
        }
        week = .object(["sessions": .array(days.map { day in
            let first = day.rows.firstIndex(where: \.main)
            return .object(["name": .string(day.name), "why": .string("The program's \(day.name)"),
                            "exercises": .array(day.rows.enumerated().map { index, row in
                var item: [String: JSON] = ["name": .string(names[row.exercise] ?? row.exercise), "main": .bool(row.main),
                                            "sets": .number(row.target("sets") ?? 3)]
                if let reps = row.target("reps") { item["reps"] = .number(reps) }
                if let seconds = row.target("duration_s") { item["seconds"] = .number(seconds) }
                if let meters = row.target("distance_m") { item["meters"] = .number(meters) }
                if let pounds = row.target("load_lb") ?? row.target("load_lb_hand") { item["pounds"] = .number(pounds) }
                if let rpe = row.target("rpe") { item["rpe"] = .number(min(10, max(5, rpe.rounded()))) }
                if let group = row.group { item["superset"] = .number(Double(group)) }
                if index == first {
                    item["change"] = .string(row.exercise.contains("squat") ? Self.changes.squat
                        : row.exercise.contains("bench") ? Self.changes.bench
                        : "\(names[row.exercise] ?? row.exercise) held: the program's load this week")
                }
                return .object(item)
            })])
        })])
    }

    func session(tools: [any Tool], instructions: String) -> any AISession { Session(week: week, calls: calls) }

    struct Session: AISession {
        let week: JSON
        let calls: Calls

        func respond(to prompt: String) async throws -> String { throw AIFailure.other }

        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
            calls.count.withLock { $0 += 1 }
            await MainActor.run { DebugRole.modelCalls += 1 }
            let answer: JSON
            if type == ProgramDesigner.DesignedWeek.self {
                answer = week
            } else if type == ProgramDesigner.FirstLoads.self, let line = prompt.components(separatedBy: "\n").last,
                      line.hasPrefix("First loads for: ") {
                let names = line.dropFirst("First loads for: ".count).dropLast().components(separatedBy: ", ")
                answer = .object(["loads": .array(names.map { .object(["name": .string($0), "pounds": .number(45)]) })])
            } else {
                throw AIFailure.other
            }
            return try Content(GeneratedContent(json: ClaudeModel.encoded(answer)))
        }
    }
}
#endif
