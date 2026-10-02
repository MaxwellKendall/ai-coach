import Foundation
import Testing
@testable import AICoach

private let monday = Date(timeIntervalSince1970: 1_784_552_400) // 2026-07-20 07:00 New York
private let wednesday = monday + 2 * 86_400
private let friday = monday + 4 * 86_400

private func workout(_ exercise: String, _ date: Date, sets: Double, rpe: Double? = nil, load: Double? = nil,
                     note: String? = nil) -> PlannedWorkout {
    PlannedWorkout(date: date, session: "S", exercise: exercise, targets: [Measurement(metric: "sets", value: sets, unit: "sets")]
        + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? [])
        + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? []), note: note)
}

private func exercise(_ slug: String, _ pattern: String, muscles: [String] = [], substitutes: [String] = []) -> Exercise {
    Exercise(slug: slug, attributes: [
        TemplateAttribute(key: "movement_pattern", values: [pattern]),
        TemplateAttribute(key: "muscles_primary", values: muscles),
        TemplateAttribute(key: "substitutes", values: substitutes),
    ])!
}

private let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4],
                                        workoutTime: 420, equipment: [], maxWeeklySets: 60)
private let patterns = ["bench": "push", "squat": "squat", "row": "pull", "plank": "core", "dl": "hinge"]

struct TrainingAdjusterTests {
    @Test func injurySwapsToASafeSubstituteAndDropsTheOldLoad() {
        let catalog = [exercise("bench", "push", muscles: ["shoulders", "chest"], substitutes: ["dips", "floor-press"]),
                       exercise("dips", "push", muscles: ["shoulders"]),
                       exercise("floor-press", "push", muscles: ["chest"]),
                       exercise("squat", "squat", muscles: ["quads"])]
        let week = TrainingWeek(workouts: [workout("bench", monday, sets: 3, load: 155), workout("squat", monday, sets: 3)],
                                deload: false, warnings: [])
        let adjusted = TrainingAdjuster.injury(week, areas: ["shoulders"], settings: settings, catalog: catalog)
        #expect(adjusted.workouts.map(\.exercise) == ["floor-press", "squat"])
        #expect(adjusted.workouts[0].target("load_lb") == nil)
        #expect(adjusted.workouts[0].target("sets") == 3) // one pattern affected: volume holds
        #expect(adjusted.workouts[0].adjustedReason == "shoulders injury: bench → floor-press")
        #expect(adjusted.workouts[1].adjustedReason == nil)
    }

    @Test func injuryAcrossPatternsCutsVolumeAndDropsWhatCantBeReplaced() {
        let catalog = [exercise("squat", "squat", muscles: ["back"]), exercise("dl", "hinge", muscles: ["back"]),
                       exercise("row", "pull", muscles: ["lats"])]
        let week = TrainingWeek(workouts: [workout("squat", monday, sets: 3), workout("dl", monday, sets: 3),
                                           workout("row", monday, sets: 4)], deload: false, warnings: [])
        let adjusted = TrainingAdjuster.injury(week, areas: ["back"], settings: settings, catalog: catalog)
        #expect(adjusted.workouts.map(\.exercise) == ["row"])
        #expect(adjusted.workouts[0].target("sets") == 3) // −25%
        #expect(adjusted.warnings.count == 2)
    }

    @Test func shortOnTimeCutsAccessoriesBeforeTheMainLift() {
        let week = TrainingWeek(workouts: [workout("bench", monday, sets: 1, note: TrainingGenerator.warmupNote),
                                           workout("bench", monday, sets: 4), workout("row", monday, sets: 3),
                                           workout("plank", monday, sets: 3), workout("squat", wednesday, sets: 3)],
                                deload: false, warnings: [])
        let adjusted = TrainingAdjuster.time(week, on: monday, minutes: 22, sessionMinutes: 45) { $0.exercise == "bench" }
        // 10 working sets × 22/45 → 5: plank and row go down to 1, then plank (last) is dropped.
        #expect(adjusted.workouts.map(\.exercise) == ["bench", "bench", "row", "squat"])
        #expect(adjusted.workouts.map { $0.target("sets") } == [1, 4, 1, 3])
        #expect(adjusted.workouts[2].adjustedReason == "22 min available")
        #expect(adjusted.workouts[3].adjustedReason == nil)
        #expect(TrainingAdjuster.time(week, on: monday, minutes: 60, sessionMinutes: 45) { _ in true } == week)
    }

    @Test func lowEnergyLowersRPEAndSetsButNeverRaisesThem() {
        let week = TrainingWeek(workouts: [workout("bench", monday, sets: 1, note: TrainingGenerator.warmupNote),
                                           workout("bench", monday, sets: 5, rpe: 8), workout("plank", monday, sets: 1),
                                           workout("squat", wednesday, sets: 3, rpe: 8)], deload: false, warnings: [])
        let adjusted = TrainingAdjuster.energy(week, on: monday)
        #expect(adjusted.workouts.map { $0.target("sets") } == [1, 4, 1, 3])
        #expect(adjusted.workouts.map { $0.target("rpe") } == [nil, 7, nil, 8])
        #expect(adjusted.workouts[0].adjustedReason == nil)
    }

    @Test func rescheduleKeeps48HoursBetweenTheSamePattern() {
        let week = TrainingWeek(workouts: [workout("bench", monday, sets: 3), workout("squat", wednesday, sets: 3),
                                           workout("bench", friday, sets: 3)], deload: false, warnings: [])
        let tuesday = monday + 86_400, thursday = wednesday + 86_400
        #expect(TrainingAdjuster.reschedule(week, from: monday, to: thursday) { patterns[$0] } == nil) // bench Fri
        let moved = TrainingAdjuster.reschedule(week, from: monday, to: tuesday) { patterns[$0] }
        #expect(moved?.workouts.map(\.date) == [tuesday, wednesday, friday])
        #expect(moved?.workouts[0].adjustedReason?.hasPrefix("moved from") == true)
    }
}
