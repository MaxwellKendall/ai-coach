import Foundation

// A new domain is a new case here plus metrics, never a new model.

enum GoalKind: String, Codable, CaseIterable, Sendable {
    case training, nutrition, body, sleep
}

enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case active, achieved, abandoned
}

/// Shared by PlannedActivity and LogEntry so a log can always be matched to its plan item.
enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case workout, meal, cook, grocery, sleep, bodyweight
}

enum TemplateKind: String, Codable, CaseIterable, Sendable {
    case exercise, recipe
}

enum WinKind: String, Codable, CaseIterable, Sendable {
    case pr, goalHit = "goal_hit", streak
}
