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
    /// FIT-54: areas the user said are fine after a pain alert, and when; only later notes bring the alert back.
    var fineAreas: [String: Date] = [:]
    var avoidExercises: [String]
    var maxWeeklySets: Int
    var style: TrainingStyle
    var warmups: Bool
    var deloadEveryWeeks: Int?
    var cookWindows: [CookWindow]
    var groceryDay: Int?
    var weeklyBudgetUSD: Double?
    /// The program (FIT-36): its first Monday and the target date that sets its length.
    var programStart: Date?
    var targetDate: Date?
    /// Program weeks away from the usual gym, 0-based.
    var travelWeeks: [Int] = []
    var starts: [StartingSet] = []
    /// FIT-95: the program brief, with what it was written for; written again when that changes (`Planner.design`).
    var brief: ProgramBrief.Stored?
    /// FIT-83: when free-plan redesigns of the week were used (`FreeLimits`).
    var redesigns: [Date] = []
    var createdAt: Date
    var updatedAt: Date

    /// Defaults are a 3-day, 45-minute full-gym week (fitness-planner's starting config).
    init(age: Int, weightLb: Double, targetWeightLb: Double? = nil, daysPerWeek: Int = 3, sessionMinutes: Int = 45,
         trainingDays: [Int] = [0, 2, 4], workoutTime: Int = 7 * 60,
         equipment: [String] = Profile.commonEquipment, injuredAreas: [String] = [], avoidExercises: [String] = [],
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

    /// FIT-70: what the catalog's exercises can need, most common first.
    static let allEquipment = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar", "kettlebells", "cable", "machine",
                               "bands", "ez_bar", "trap_bar", "dip_station", "suspension", "box", "medicine_ball",
                               "exercise_ball", "sled", "bike", "rower", "treadmill", "jump_rope"]
    /// A barbell home gym: what onboarding starts with, and the first chips shown.
    static let commonEquipment = Array(allEquipment.prefix(5))

    var trainingSettings: TrainingSettings {
        TrainingSettings(age: age, daysPerWeek: trainingDays.count, sessionMinutes: sessionMinutes,
                         trainingDays: Week.ordered(trainingDays), workoutTime: workoutTime, equipment: Set(equipment),
                         injuredAreas: BodyArea.muscles(for: injuredAreas), avoidExercises: Set(avoidExercises),
                         maxWeeklySets: maxWeeklySets, style: style, warmups: warmups, deloadEveryWeeks: deloadEveryWeeks,
                         starts: starts, bodyWeight: weightLb)
    }

    /// The program's weeks, when there is one.
    var program: [ProgramWeek]? {
        guard let programStart, let targetDate else { return nil }
        return ProgramPlan.weeks(count: ProgramPlan.weekCount(start: programStart, target: targetDate),
                                 deloadEvery: deloadEveryWeeks ?? AgeTier.of(age: age).deloadEveryWeeks,
                                 travel: Set(travelWeeks))
    }

    /// The program week a date falls in, if it's within the program.
    func programWeek(of date: Date, calendar: Calendar = .current) -> (index: Int, week: ProgramWeek)? {
        guard let weeks = program, let programStart else { return nil }
        let index = ProgramPlan.week(of: date, start: programStart, calendar: calendar)
        return weeks.indices.contains(index) ? (index, weeks[index]) : nil
    }
}
