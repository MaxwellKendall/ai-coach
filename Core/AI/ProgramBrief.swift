import Foundation
import FoundationModels

/// FIT-95: the program's plan, written once by the model and given to every week's design, so the weeks add up to one
/// program (FIT-94: designed a week at a time without it, the goal lift was trained in 3 weeks of 12). The model
/// chooses each phase's focus, main lifts and reps (principle 4); code says where each goal should be each week
/// (`ProgramPlan.expected`). Kept on the profile with what it was written for, and written again when that changes.
@Generable
struct ProgramBrief: Codable, Equatable, Sendable {
    @Guide(description: "One per phase listed, in order", .minimumCount(1), .maximumCount(3))
    var phases: [Phase]

    @Generable
    struct Phase: Codable, Equatable, Sendable {
        @Guide(.anyOf(["base", "build", "peak"]))
        var phase: String
        @Guide(description: "Its focus, in a few words")
        var focus: String
        @Guide(description: "2 to 4 main lifts for every hard week of the phase, exactly as listed; every goal lift among them",
               .minimumCount(1), .maximumCount(4))
        var mainLifts: [String]
        @Guide(description: "Reps a set for the main lifts", .range(1...15))
        var mainReps: Int
        @Guide(description: "Reps a set for the rest", .range(5...20))
        var accessoryReps: Int
    }

    func phase(_ phase: ProgramPhase) -> Phase? { phases.first { $0.phase == phase.rawValue } }

    /// The brief on the profile, with what it was written for.
    struct Stored: Codable, Equatable, Sendable {
        var brief: ProgramBrief
        /// `ProgramBrief.key` when it was written.
        var key: String
        var model: String
    }

    /// What a brief is written from, as one string: a change to any of it means writing the brief again.
    static func key(goals: [String], settings: TrainingSettings, weeks: [ProgramWeek]) -> String {
        [goals.sorted().joined(separator: ";"), settings.trainingDays.map(String.init).joined(separator: ","), "\(settings.sessionMinutes)",
         settings.equipment.sorted().joined(separator: ","), settings.injuredAreas.sorted().joined(separator: ","),
         settings.avoidExercises.sorted().joined(separator: ","), settings.style.rawValue,
         weeks.map { $0.kind.rawValue + ($0.travel ? "t" : "") }.joined(separator: ",")].joined(separator: "|")
    }

    // MARK: Writing it

    struct Request: Sendable {
        var settings: TrainingSettings
        var catalog: [Exercise]
        var names: [String: String]
        /// "Bench Press 225 lb by Jan 9".
        var goals: [String]
        var goalLifts: [GoalLift]
        var weeks: [ProgramWeek]
    }

    /// nil when the model isn't available or fails; weeks are then designed without a brief, as before.
    static func write(_ request: Request, model: any AIModel = OnDeviceModel()) async -> ProgramBrief? {
        guard model.isAvailable, !request.weeks.isEmpty else { return nil }
        for _ in 0..<2 {
            let session = model.session(instructions: instructions)
            if let brief = try? await session.respond(to: prompt(request), generating: ProgramBrief.self) {
                let checked = checked(brief, request)
                if !checked.phases.isEmpty { return checked }
            }
        }
        return nil
    }

    static let instructions = """
        You are a strength coach planning the phases of one person's training program. For each phase listed, choose \
        its focus, 2 to 4 main lifts for every hard week, and reps a set for the main lifts and for the rest. Every \
        goal's lift is a main lift in every phase. Phases build on each other: base has more reps and volume, build is \
        heavier, peak is heaviest with the fewest reps for the goal lifts. Choose main lifts from the menu, written exactly.
        """

    static func prompt(_ request: Request) -> String {
        let settings = request.settings
        var lines: [String] = []
        if !request.goals.isEmpty { lines.append("Goals: \(request.goals.joined(separator: "; ")).") }
        let lifts = request.goalLifts.map { lift in
            let name = request.names[lift.exercise] ?? lift.exercise
            return lift.measure == "reps" ? "\(name) (\(Coach.number(lift.start)) in a row now, \(Coach.number(lift.target)) at the end)"
                : "\(name) (estimated max \(Coach.number(lift.start.rounded())) lb now, \(Coach.number(lift.target)) at the end)"
        }
        if !lifts.isEmpty { lines.append("Goal lifts: \(lifts.joined(separator: "; ")).") }
        lines.append("Program: \(request.weeks.count) weeks. " + shape(request.weeks))
        let days = settings.trainingDays.prefix(settings.daysPerWeek).map { ProgramDesigner.weekdays[$0 % 7] }
        lines.append("Training days: \(days.joined(separator: ", ")), \(settings.sessionMinutes) minutes each.")
        lines.append("Age \(settings.age)\(settings.bodyWeight.map { ", \(Coach.number($0)) lb" } ?? ""). Style: \(settings.style.rawValue).")
        lines.append("Equipment: \(settings.equipment.isEmpty ? "none, bodyweight only" : settings.equipment.sorted().map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).")
        if !settings.injuredAreas.isEmpty { lines.append("Injured: \(settings.injuredAreas.sorted().joined(separator: ", ")).") }
        lines.append("Menu of main lifts, by movement:\n" + menu(request))
        lines.append("Plan these phases: \(phases(request.weeks).map(\.rawValue).joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    static let menuMovements = ["squat", "hinge", "lunge", "horizontal push", "vertical push", "horizontal pull", "vertical pull"]

    private static func menu(_ request: Request) -> String {
        let goalNames = request.goalLifts.compactMap { request.names[$0.exercise] }
        return menuMovements.compactMap { movement in
            var found = ExerciseSearch.find(movement, in: request.catalog, names: request.names, settings: request.settings, limit: 4)
                .map { request.names[$0] ?? $0 }
            // A goal lift is always on the menu under its movement.
            for name in goalNames where !found.contains(name) {
                if let slug = request.names.first(where: { $0.value == name })?.key,
                   ExerciseSearch.find(movement, in: request.catalog, names: request.names, settings: request.settings, limit: 40).contains(slug) {
                    found.insert(name, at: 0)
                }
            }
            return found.isEmpty ? nil : "\(movement.prefix(1).uppercased() + movement.dropFirst()): \(found.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// The phases the program has, in order.
    static func phases(_ weeks: [ProgramWeek]) -> [ProgramPhase] {
        [ProgramPhase.base, .build, .peak].filter { phase in weeks.contains { $0.phase == phase } }
    }

    /// "Weeks 1–4 base, 5–9 build, 10–12 peak. Deloads in weeks 6 and 11; week 12 a test week."
    static func shape(_ weeks: [ProgramWeek]) -> String {
        func span(_ indices: [Int]) -> String {
            guard let first = indices.first, let last = indices.last else { return "" }
            return first == last ? "\(first + 1)" : "\(first + 1)–\(last + 1)"
        }
        let phases = phases(weeks).map { phase in "\(span(weeks.indices.filter { weeks[$0].phase == phase })) \(phase.rawValue)" }
        var text = "Weeks " + phases.joined(separator: ", ") + "."
        let deloads = weeks.indices.filter { weeks[$0].kind == .deload }.map { "\($0 + 1)" }
        if !deloads.isEmpty { text += " Deloads in week\(deloads.count == 1 ? "" : "s") \(deloads.joined(separator: " and "))." }
        if let test = weeks.indices.last(where: { weeks[$0].kind == .test }) { text += " Week \(test + 1) a test week." }
        return text
    }

    /// Phases the program has, in its order, each once; main lifts the catalog has under its own names, each once.
    /// What's left is the model's choice.
    static func checked(_ brief: ProgramBrief, _ request: Request) -> ProgramBrief {
        let bySlug = Dictionary(request.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let phases = phases(request.weeks).compactMap { phase -> Phase? in
            guard var line = brief.phase(phase) else { return nil }
            line.focus = line.focus.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            line.mainLifts = line.mainLifts.compactMap { PlanGuard.resolve($0, in: bySlug, names: request.names) }
                .map { request.names[$0.slug] ?? $0.slug }
                .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            return line
        }
        return ProgramBrief(phases: phases)
    }
}
