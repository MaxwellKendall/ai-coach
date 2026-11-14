import Foundation

/// FIT-454: everything the first-launch quiz asks (the AbMaxx-style spec, screens 2–18), and what it picks from them.
/// Pure, so the picks are tested; saving to the profile is `StartFlow`'s.
struct StartAnswers: Codable, Equatable, Sendable {
    enum Goal: String, Codable, CaseIterable, Sendable { case stronger, muscle, leaner, consistent, comeback }
    enum Body: String, Codable, CaseIterable, Sendable { case slim, average, athletic, stocky }
    enum Activity: String, Codable, CaseIterable, Sendable { case low, moderate, high }
    enum Place: String, Codable, CaseIterable, Sendable { case commercial, home, both, other }
    enum Holdback: String, Codable, CaseIterable, Sendable { case noProgram, missSessions, noProgress, plateau, unsure }

    var goal: Goal?
    var sex: StrengthCheck.Sex?
    var age = 30
    var heightIn = 69.0
    var weightLb: Double?
    /// The units picked for height and weight; lb and ft/in unless they pick metric.
    var metric = false
    var days = 3
    var body: Body?
    var activity: Activity?
    var place: Place?
    var equipment: Set<String> = []
    var holdback: Holdback?
    var name = ""
    var lifts: [StrengthCheck.Entry] = []

    var firstName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The ready program's goal, for `ReadyProgram.matches`.
    var programGoal: ReadyProgram.Goal { goal == .muscle ? .muscle : .strength }

    /// Where they train, as the equipment it usually means; the next screen starts ticked from it.
    static func equipment(for place: Place) -> Set<String> {
        switch place {
        case .commercial, .both: Set(Profile.allEquipment)
        case .home: ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"]
        case .other: []
        }
    }

    /// The program that fits, and its training days. Lifts given means they've lifted; the check skipped picks a
    /// program for someone newer, unless they're coming back.
    func program(in programs: [ReadyProgram] = ReadyProgram.all) -> (program: ReadyProgram, days: [Int])? {
        let lifted: Bool? = !lifts.isEmpty || goal == .comeback ? true : nil
        guard let program = ReadyProgram.matches(have: equipment, days: days, goal: programGoal, lifted: lifted, in: programs).first
                ?? programs.first else { return nil }
        return (program, ReadyProgram.days(for: program.days(nearest: days)))
    }

    func result() -> StrengthCheck.Result? {
        let favored: String? = goal == .stronger ? "back-squat" : nil
        return StrengthCheck.result(lifts, bodyweight: weightLb ?? 0, sex: sex ?? .unspecified, favoring: favored)
    }
}
