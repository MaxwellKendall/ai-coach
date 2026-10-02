import Foundation

/// Starting goals from the age tier and body weight (fitness-planner CLAUDE.md "Age-Bracket Goal Tiers"
/// and "Daily nutrition targets"). Only proposals: the user accepts or edits each one.
enum GoalSuggestions {
    private struct Tier {
        var squat: Double, hinge: Double, push: Double   // × body weight, barbell
        var pushUps: Int, pullUps: Int, fiveKMinutes: Double
    }

    private static func tier(age: Int) -> Tier {
        switch age {
        case ..<30: Tier(squat: 1.5, hinge: 2.0, push: 1.25, pushUps: 20, pullUps: 15, fiveKMinutes: 22)
        case 30..<40: Tier(squat: 1.25, hinge: 1.75, push: 1.0, pushUps: 15, pullUps: 10, fiveKMinutes: 25)
        case 40..<50: Tier(squat: 1.0, hinge: 1.5, push: 0.85, pushUps: 12, pullUps: 8, fiveKMinutes: 28)
        case 50..<60: Tier(squat: 0.85, hinge: 1.25, push: 0.7, pushUps: 10, pullUps: 5, fiveKMinutes: 32)
        default: Tier(squat: 0.65, hinge: 1.0, push: 0.55, pushUps: 8, pullUps: 3, fiveKMinutes: 38)
        }
    }

    /// Barbell strength targets need a barbell and rack ("Goal targets are equipment-aware"); without them
    /// the push goal is push-ups. Pull-ups need a bar. Metrics already set as goals are left out.
    static func suggestions(age: Int, weightLb: Double, targetWeightLb: Double?, equipment: Set<String>,
                            existing: Set<String> = []) -> [GoalSeed] {
        let tier = tier(age: age)
        func lb(_ multiple: Double) -> Double { (weightLb * multiple / 5).rounded() * 5 }
        var goals: [GoalSeed] = []
        if equipment.isSuperset(of: ["barbell", "rack"]) {
            goals.append(GoalSeed(kind: .training, metric: "back-squat.1rm_lb", target: lb(tier.squat), unit: "lb"))
            goals.append(GoalSeed(kind: .training, metric: "bench-press.1rm_lb", target: lb(tier.push), unit: "lb"))
            goals.append(GoalSeed(kind: .training, metric: "deadlift.1rm_lb", target: lb(tier.hinge), unit: "lb"))
        } else {
            goals.append(GoalSeed(kind: .training, metric: "push-up.reps", target: Double(tier.pushUps), unit: "reps"))
        }
        if equipment.contains("pull_up_bar") {
            goals.append(GoalSeed(kind: .training, metric: "pull-up.reps", target: Double(tier.pullUps), unit: "reps"))
        }
        goals.append(GoalSeed(kind: .training, metric: "5k.duration_min", target: tier.fiveKMinutes, unit: "min"))
        goals.append(GoalSeed(kind: .nutrition, metric: "protein_g", target: (weightLb * 0.8).rounded(), unit: "g"))
        if let target = targetWeightLb, target != weightLb {
            goals.append(GoalSeed(kind: .body, metric: "weight_lb", target: target, unit: "lb"))
        }
        return goals.filter { !existing.contains($0.metric) }
    }
}
