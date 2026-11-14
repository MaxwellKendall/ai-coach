import Foundation

/// FIT-455: the onboarding's strength check, in place of AbMaxx's ab scan. Each lift's best recent set becomes a Brzycki
/// estimated max (`ProgramPlan.estimatedMax`), divided by body weight and scored 0–100 against bodyweight standards by
/// sex. Only the weakest lift is shown plainly; the overall score and the other lifts are blurred until they subscribe.
enum StrengthCheck {
    enum Sex: String, Codable, CaseIterable, Sendable { case male, female, unspecified }

    /// The four lifts the check scores, in the order ties are broken (bench, then squat, then deadlift, then press).
    static let lifts: [(slug: String, name: String)] = [
        ("bench-press", "Bench"), ("back-squat", "Squat"), ("deadlift", "Deadlift"), ("standing-military-press", "Overhead press"),
    ]

    static func name(_ slug: String) -> String { lifts.first { $0.slug == slug }?.name ?? slug }

    /// Estimated max ÷ body weight at the beginner, novice, intermediate, advanced and elite levels. Rounded from common
    /// published strength standards; they place a lift, they don't judge anyone.
    static func standards(_ slug: String, _ sex: Sex) -> [Double] {
        let male: [String: [Double]] = [
            "back-squat": [0.75, 1.25, 1.5, 2.25, 2.75], "bench-press": [0.5, 0.75, 1.0, 1.5, 2.0],
            "deadlift": [1.0, 1.5, 2.0, 2.5, 3.0], "standing-military-press": [0.35, 0.55, 0.75, 1.0, 1.35],
        ]
        let female: [String: [Double]] = [
            "back-squat": [0.5, 0.75, 1.25, 1.5, 2.0], "bench-press": [0.25, 0.5, 0.75, 1.0, 1.25],
            "deadlift": [0.5, 1.0, 1.25, 1.75, 2.25], "standing-military-press": [0.2, 0.35, 0.5, 0.75, 1.0],
        ]
        let m = male[slug] ?? [0.5, 1, 1.5, 2, 2.5], f = female[slug] ?? m
        switch sex {
        case .male: return m
        case .female: return f
        case .unspecified: return zip(m, f).map { ($0 + $1) / 2 }
        }
    }

    /// 0–100: 20 at beginner, 40 novice, 60 intermediate, 80 advanced, 100 elite, straight lines between.
    static func score(_ slug: String, estimatedMax: Double, bodyweight: Double, sex: Sex) -> Int {
        guard bodyweight > 0, estimatedMax > 0 else { return 0 }
        let ratio = estimatedMax / bodyweight
        let levels = [0.0] + standards(slug, sex)
        for index in 1..<levels.count where ratio <= levels[index] {
            let low = levels[index - 1], high = levels[index]
            return Int((Double(index - 1) * 20 + (ratio - low) / (high - low) * 20).rounded())
        }
        return 100
    }

    /// One lift's best recent set.
    struct Entry: Codable, Equatable, Hashable, Sendable {
        var slug: String
        var weight: Double
        var reps: Double

        var estimatedMax: Double { ProgramPlan.estimatedMax(load: weight, reps: reps) }
    }

    struct Result: Equatable, Sendable {
        var scores: [String: Int]
        var weakest: String
        var overall: Int
    }

    /// Nil without a lift to score. `goal` breaks ties: a lift it names first, then the fixed order of `lifts`.
    static func result(_ entries: [Entry], bodyweight: Double, sex: Sex, favoring goal: String? = nil) -> Result? {
        let scores = Dictionary(entries.map { ($0.slug, score($0.slug, estimatedMax: $0.estimatedMax, bodyweight: bodyweight, sex: sex)) },
                                uniquingKeysWith: max)
        guard let low = scores.values.min() else { return nil }
        let order = lifts.map(\.slug)
        let tied = scores.filter { $0.value == low }.keys.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        let weakest = tied.first { $0 == goal } ?? tied[0]
        let overall = Int((Double(scores.values.reduce(0, +)) / Double(scores.count)).rounded())
        return Result(scores: scores, weakest: weakest, overall: overall)
    }
}
