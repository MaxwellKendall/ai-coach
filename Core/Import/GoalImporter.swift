import Foundation

struct GoalSeed: Codable, Hashable, Sendable {
    var kind: GoalKind
    var metric: String
    var target: Double
    var unit: String
    var deadline: Date?
}

/// Converts fitness-planner `profile.json` `active_goals` into goals. Targets there are prose
/// ("250 lb back squat (1.25× bodyweight)"), so each known goal says where its number is.
enum GoalImporter {
    private struct Spec: Sendable {
        var kind: GoalKind
        var metric: String
        var unit: String
        var pattern: String
    }

    private static let specs: [String: [Spec]] = [
        "squat": [Spec(kind: .training, metric: "back-squat.1rm_lb", unit: "lb", pattern: #"(\d+(?:\.\d+)?)\s*lb"#)],
        "hinge": [Spec(kind: .training, metric: "deadlift.1rm_lb", unit: "lb", pattern: #"(\d+(?:\.\d+)?)\s*lb"#)],
        "push": [Spec(kind: .training, metric: "bench-press.1rm_lb", unit: "lb", pattern: #"(\d+(?:\.\d+)?)\s*lb"#)],
        "pull": [Spec(kind: .training, metric: "pull-up.reps", unit: "reps", pattern: #"(\d+)\s*unbroken"#)],
        "body_composition": [
            Spec(kind: .body, metric: "weight_lb", unit: "lb", pattern: #"(\d+(?:\.\d+)?)\s*lb"#),
            Spec(kind: .body, metric: "waist_in", unit: "in", pattern: #"waist\D*(\d+(?:\.\d+)?)"#),
        ],
        "cardio": [Spec(kind: .training, metric: "5k.duration_min", unit: "min", pattern: #"(\d+(?:\.\d+)?)\s*min"#)],
    ]

    /// Deadline is `generated_at` + `timeline_weeks_remaining`, the planning horizon the goals were set for.
    static func goals(profileJSON: String, calendar: Calendar = .current) -> (goals: [GoalSeed], skipped: [String]) {
        guard let profile = try? JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any],
              let active = profile["active_goals"] as? [String: Any] else {
            return ([], ["profile.json: no active_goals"])
        }
        var deadline: Date?
        if let generated = (profile["generated_at"] as? String).flatMap({ HistoryImporter.date($0, calendar: calendar) }),
           let weeks = active["timeline_weeks_remaining"] as? Int {
            deadline = calendar.date(byAdding: .weekOfYear, value: weeks, to: generated)
        }

        var goals: [GoalSeed] = [], skipped: [String] = []
        let order = ["squat", "push", "hinge", "pull", "cardio", "body_composition"]
        for key in order.filter(active.keys.contains) + active.keys.filter({ !order.contains($0) }).sorted() {
            guard let goal = active[key] as? [String: Any], let text = goal["target"] as? String else { continue }
            guard let specs = specs[key] else {
                skipped.append("\(key): no numeric target (\(text))")
                continue
            }
            for spec in specs {
                guard let regex = try? NSRegularExpression(pattern: spec.pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text), let target = Double(text[range]) else {
                    skipped.append("\(key): can't read \(spec.metric) from \(text)")
                    continue
                }
                goals.append(GoalSeed(kind: spec.kind, metric: spec.metric, target: target, unit: spec.unit, deadline: deadline))
            }
        }
        return (goals, skipped)
    }
}

extension Goal {
    /// "back-squat.1rm_lb" → "Back Squat 1RM", "weight_lb" → "Body weight".
    static func label(_ metric: String) -> String {
        let parts = metric.split(separator: ".").map(String.init)
        let measures = ["1rm_lb": "1RM", "reps": "reps", "duration_min": "time", "weight_lb": "Body weight",
                        "waist_in": "Waist", "protein_g": "Protein", "kcal": "Calories", "sleep_h": "Sleep"]
        let measure = measures[parts.last ?? ""] ?? (parts.last ?? metric)
        guard parts.count > 1 else { return measure }
        let subject = parts[0].split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "\(subject) \(measure)"
    }
}
