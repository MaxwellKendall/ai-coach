import Foundation
import SwiftData

/// A weekly kitchen block, e.g. Saturday 2 h "weekly bulk cook". `day` is 0 = Monday.
struct CookWindow: Codable, Hashable, Sendable {
    var day: Int
    var hours: Double
    var label: String
}

/// The athlete's own settings, collected once at onboarding (replaces fitness-planner's config.yaml).
/// User-owned: the app proposes changes but never writes them itself.
@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var age: Int
    var weightLb: Double
    var targetWeightLb: Double?
    var daysPerWeek: Int
    var sessionMinutes: Int
    /// 0 = Monday.
    var trainingDays: [Int]
    /// Minutes after midnight.
    var workoutTime: Int
    var equipment: [String]
    var injuredAreas: [String]
    var avoidExercises: [String]
    var maxWeeklySets: Int
    var style: TrainingStyle
    var warmups: Bool
    var deloadEveryWeeks: Int?
    var cookWindows: [CookWindow]
    var groceryDay: Int?
    var weeklyBudgetUSD: Double?
    var createdAt: Date
    var updatedAt: Date

    /// Defaults are a 3-day, 45-minute full-gym week (fitness-planner's starting config).
    init(age: Int, weightLb: Double, targetWeightLb: Double? = nil, daysPerWeek: Int = 3, sessionMinutes: Int = 45,
         trainingDays: [Int] = [0, 2, 4], workoutTime: Int = 7 * 60,
         equipment: [String] = Profile.allEquipment, injuredAreas: [String] = [], avoidExercises: [String] = [],
         maxWeeklySets: Int = 60, style: TrainingStyle = .powerbuilding, warmups: Bool = true,
         deloadEveryWeeks: Int? = nil, cookWindows: [CookWindow] = [], groceryDay: Int? = nil,
         weeklyBudgetUSD: Double? = nil, now: Date = .now) {
        self.id = UUID()
        self.age = age
        self.weightLb = weightLb
        self.targetWeightLb = targetWeightLb
        self.daysPerWeek = daysPerWeek
        self.sessionMinutes = sessionMinutes
        self.trainingDays = trainingDays
        self.workoutTime = workoutTime
        self.equipment = equipment
        self.injuredAreas = injuredAreas
        self.avoidExercises = avoidExercises
        self.maxWeeklySets = maxWeeklySets
        self.style = style
        self.warmups = warmups
        self.deloadEveryWeeks = deloadEveryWeeks
        self.cookWindows = cookWindows
        self.groceryDay = groceryDay
        self.weeklyBudgetUSD = weeklyBudgetUSD
        self.createdAt = now
        self.updatedAt = now
    }

    static let allEquipment = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"]

    var trainingSettings: TrainingSettings {
        TrainingSettings(age: age, daysPerWeek: trainingDays.count, sessionMinutes: sessionMinutes,
                         trainingDays: trainingDays.sorted(), workoutTime: workoutTime, equipment: Set(equipment),
                         injuredAreas: Set(injuredAreas), avoidExercises: Set(avoidExercises),
                         maxWeeklySets: maxWeeklySets, style: style, warmups: warmups, deloadEveryWeeks: deloadEveryWeeks)
    }
}
