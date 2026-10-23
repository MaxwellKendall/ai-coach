import Foundation

/// FIT-230: a ready-made program for someone training without a coach, from `Resources/Seed/programs.json`. Generic
/// structures anyone may use (full-body A/B, upper/lower, push/pull/legs), under our own names, never a brand's.
struct ReadyProgram: Codable, Equatable, Identifiable, Sendable {
    /// What a program is built around: a barbell, dumbbells or body weight.
    enum Place: String, Codable, CaseIterable, Sendable {
        case gym, dumbbells, bodyweight

        /// What equipment someone has is mostly for: a barbell makes the barbell programs the fit.
        init(_ have: Set<String>) {
            self = have.isSuperset(of: ["barbell", "rack"]) ? .gym : have.contains("dumbbells") ? .dumbbells : .bodyweight
        }
    }

    /// Onboarding's "What do you have?": each line and the catalog equipment it stands for.
    static let kit: [(name: String, equipment: [String])] = [
        ("Barbell and rack", ["barbell", "rack"]), ("Bench", ["bench"]), ("Dumbbells", ["dumbbells"]),
        ("Pull-up bar", ["pull_up_bar"]), ("Cables and machines", ["cable", "machine"]),
    ]

    /// The equipment kept on the profile: every line ticked is a full gym, with the rest of the catalog's equipment.
    static func equipment(_ have: Set<String>) -> [String] {
        kit.allSatisfy({ have.isSuperset(of: $0.equipment) }) ? Profile.allEquipment : Profile.allEquipment.filter(have.contains)
    }

    struct Item: Codable, Equatable, Sendable {
        /// One exercise, or `ladder`: one movement from easiest to hardest, moved up once the top of the reps is reached.
        var exercise: String?
        var ladder: [String]?
        /// Stand-ins, in order, when the equipment doesn't allow `exercise`.
        var or: [String]?
        var sets: Int
        /// The rep range; one number (5–5) adds load every session it's all done.
        var reps: [Int]?
        /// A hold's range in seconds, instead of reps.
        var seconds: [Int]?
        /// The first session's load in lb (a hand, for dumbbells); nil for bodyweight.
        var start: Double?
        /// Load added once the reps are all done. 5 lb unless said.
        var step: Double?
        var main: Bool?
        /// Consecutive items with one number are a superset, done in rounds.
        var group: Int?

        var choices: [String] { ladder ?? ([exercise].compactMap { $0 } + (or ?? [])) }
    }

    struct Session: Codable, Equatable, Sendable {
        var name: String
        var exercises: [Item]
    }

    var slug: String
    var name: String
    var summary: String
    /// "new" or "some" (some experience).
    var level: String
    var place: Place
    /// The days a week it can run on.
    var days: [Int]
    var weeks: Int
    var minutes: Int
    var equipment: [String]
    /// Equipment it uses when there is some: a pull-up bar adds pull-ups.
    var optional: [String]?
    /// Done in turn, one per training day, carrying on across weeks.
    var sessions: [Session]

    var id: String { slug }

    static let all: [ReadyProgram] = Bundle.main.url(forResource: "programs", withExtension: "json")
        .flatMap { try? JSONDecoder().decode([ReadyProgram].self, from: Data(contentsOf: $0)) } ?? []

    static func named(_ slug: String?) -> ReadyProgram? { all.first { $0.slug == slug } }

    /// The programs the equipment allows, best first: nearest in days a week, then the ones built around what the
    /// equipment is mostly for, then the file's order (which lists beginner programs first).
    static func matches(have: Set<String>, days: Int, in programs: [ReadyProgram] = all) -> [ReadyProgram] {
        let place = Place(have)
        return programs.enumerated()
            .filter { Set($0.element.equipment).isSubset(of: have) }
            .sorted { a, b in
                func key(_ item: (offset: Int, element: ReadyProgram)) -> [Int] {
                    [abs(item.element.days(nearest: days) - days), item.element.place == place ? 0 : 1, item.offset]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            .map(\.element)
    }

    /// Its days a week closest to `wanted`, the fewer on a tie.
    func days(nearest wanted: Int) -> Int {
        days.min { abs($0 - wanted) == abs($1 - wanted) ? $0 < $1 : abs($0 - wanted) < abs($1 - wanted) } ?? wanted
    }

    /// Training days (0 = Monday) to start with: spread out, with a rest day between where the count allows.
    static func days(for count: Int) -> [Int] {
        [1: [0], 2: [0, 3], 3: [0, 2, 4], 4: [0, 1, 3, 4], 5: [0, 1, 2, 4, 5], 6: [0, 1, 2, 3, 4, 5], 7: Array(0..<7)][count] ?? [0, 2, 4]
    }
}

extension ReadyProgram {
    /// A week's heading where the program is shown: no base, build or peak, only the deload.
    func title(_ week: ProgramWeek) -> String { week.kind == .deload ? ProgramPlan.title(week) : name }

    func why(_ week: ProgramWeek) -> String {
        week.kind == .deload ? ProgramPlan.why(week) : "A little heavier, or a rep more, wherever last time went to plan."
    }
}
