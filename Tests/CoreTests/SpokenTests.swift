import Foundation
import Testing
@testable import AICoach

/// FIT-29 and FIT-30: what was said, matched to the plan by code.
struct SpokenTests {
    private let names = ["bench-press": "Bench Press", "deadlift": "Deadlift", "dumbbell-row": "Dumbbell Row (Single-Arm)",
                         "dumbbell-bench-press": "Dumbbell Bench Press", "dead-bug": "Dead Bug"]

    private func item(_ exercise: String, sets: Double, reps: Double, load: Double?, group: Int? = nil) -> SessionPlan.Item {
        SessionPlan.Item(id: UUID(), exercise: exercise, targets: [
            Measurement(metric: "sets", value: sets, unit: "sets"), Measurement(metric: "reps", value: reps, unit: "reps")]
            + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []), group: group)
    }

    private var sessionB: WorkoutDraft {
        WorkoutDraft(session: "Session B", plan: SessionPlan([
            item("bench-press", sets: 3, reps: 5, load: 140), item("deadlift", sets: 3, reps: 5, load: 225),
            item("dumbbell-bench-press", sets: 3, reps: 10, load: 50), item("dead-bug", sets: 2, reps: 10, load: nil)]))
    }

    @Test func benchMeansTheBarbellLiftNotTheDumbbellOne() {
        let exercises = ["dumbbell-bench-press", "bench-press", "deadlift"]
        #expect(SpokenLog.match("bench", in: exercises, names: names) == "bench-press")
        #expect(SpokenLog.match("dumbbell bench", in: exercises, names: names) == "dumbbell-bench-press")
        #expect(SpokenLog.match("deadlifts", in: exercises, names: names) == "deadlift")
        #expect(SpokenLog.match("squat", in: exercises, names: names) == nil)
    }

    @Test func didItLogsThePlanAndOnlyTheSpokenDifference() {
        var draft = sessionB
        let changed = SpokenLog.apply([.init(exercise: "bench", set: .max, reps: 4)], to: &draft, names: names)
        #expect(draft.rows.allSatisfy { $0.done })
        #expect(changed == [2])
        #expect(draft.rows[2].value == 4 && draft.rows[2].heard && draft.rows[2].plannedValue == 5)
        #expect(!draft.rows[1].heard)
    }

    @Test func differencesCanNameASetOrAllOfThem() {
        var draft = sessionB
        let changed = SpokenLog.apply([.init(exercise: "deadlift", pounds: 235), .init(exercise: "bench", set: 2, reps: 5)],
                                      to: &draft, names: names)
        #expect(changed == [3, 4, 5]) // bench set 2 was already 5, so it isn't a change
        #expect(draft.rows[3...5].allSatisfy { $0.load == 235 })
        var unknown = sessionB
        #expect(SpokenLog.apply([.init(exercise: "squat", reps: 3), .init(exercise: "bench", set: 9, reps: 3)],
                                to: &unknown, names: names).isEmpty)
    }

    @Test func talkingMidWorkoutOnlyLogsTheCardItsAbout() {
        var draft = sessionB
        let changed = SpokenLog.apply([.init(exercise: "Bench Press", set: .max, reps: 4)], to: &draft, names: names, line: [1])
        #expect(changed == [1])
        #expect(draft.rows.indices.filter { draft.rows[$0].done } == [1]) // that set only
        var named = sessionB
        #expect(SpokenLog.apply([.init(exercise: "bench", set: 3, reps: 6)], to: &named, names: names, line: [0]) == [2])
        #expect(named.rows[0].done && named.rows[2].done && named.rows[2].value == 6)
        var deadlift = sessionB
        #expect(SpokenLog.apply([], to: &deadlift, names: names, line: [3]).isEmpty) // "done": logged as planned
        #expect(deadlift.rows.indices.filter { deadlift.rows[$0].done } == [3])
    }

    @Test func theParseOnlyKeepsWhatTheRulesCanUse() {
        func draft(_ kind: String, minutes: Int? = nil, lowEnergy: Bool? = nil, hurts: String? = nil, moveTo: String? = nil,
                   differences: [TodayWorkoutDraft.Difference] = []) -> TodayRequestDraft {
            TodayRequestDraft(kind: kind, minutes: minutes, lowEnergy: lowEnergy, hurts: hurts, moveTo: moveTo, differences: differences)
        }
        #expect(SpokenRequest(draft("change", minutes: 30))?.kind == .change(.time(minutes: 30)))
        // "Make the plank a minute" isn't a session length (FIT-49).
        #expect(SpokenRequest(draft("change", minutes: 1)) == nil)
        #expect(SpokenRequest(draft("change", hurts: "Shoulder"))?.kind == .change(.injury(area: "Shoulder")))
        #expect(SpokenRequest(draft("change", moveTo: "saturday"))?.kind == .change(.move(weekday: 5)))
        #expect(SpokenRequest(draft("change", lowEnergy: true))?.kind == .change(.energy))
        #expect(SpokenRequest(draft("change")) == nil)
        #expect(SpokenRequest(draft("did_workout", differences: [.init(exercise: "bench", set: "last", reps: 4, pounds: nil)]))?.kind
                == .didWorkout([.init(exercise: "bench", set: .max, reps: 4)]))
        #expect(SpokenRequest(draft("log"))?.kind == .log)
    }

    private func workout(_ exercise: String, sets: Double, load: Double? = nil, group: Int? = nil) -> PlannedWorkout {
        PlannedWorkout(date: .now, session: "Session B", exercise: exercise,
                       targets: [Measurement(metric: "sets", value: sets, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps")]
                           + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []), group: group)
    }

    @Test func fieldsNobodySaidAreDropped() {
        let invented = TodayRequestDraft(kind: "did_workout", differences: [
            .init(exercise: "chest press", set: "2", reps: 10, pounds: 100), .init(exercise: "bench", set: "last", reps: 4, pounds: nil)])
        #expect(SpokenRequest.checked(invented, against: "Did it. Last bench set was only four.").differences.map(\.exercise) == ["bench"])
        let change = TodayRequestDraft(kind: "change", minutes: 30, lowEnergy: false, hurts: "shoulder", moveTo: "saturday")
        let checked = SpokenRequest.checked(change, against: "I only have thirty minutes today")
        #expect(checked.minutes == 30 && checked.hurts == nil && checked.moveTo == nil)
        #expect(SpokenRequest.checked(change, against: "my shoulder hurts").hurts == "shoulder")
        let allSets = TodayRequestDraft(kind: "did_workout", differences: [.init(exercise: "deadlifts", set: "last", reps: nil, pounds: 235)])
        #expect(SpokenRequest.checked(allSets, against: "deadlifts were at two thirty five").differences.first?.set == nil)
        let mid = TodayRequestDraft(kind: "did_workout", differences: [.init(exercise: "x", set: nil, reps: 4, pounds: nil)])
        #expect(SpokenRequest.checked(mid, against: "only got four on the last one", current: "Bench Press").differences.first?.exercise
                == "Bench Press")
        #expect(SpokenRequest.checked(TodayRequestDraft(kind: "change"), against: "slept badly, feeling wrecked").lowEnergy == true)
    }

    @Test func aThirtyMinuteDayReadsLikeThePrototype() {
        let before = [workout("bench-press", sets: 3, load: 140), workout("deadlift", sets: 3, load: 225),
                      workout("dumbbell-row", sets: 3, group: 2), workout("dumbbell-bench-press", sets: 3, group: 2),
                      workout("dead-bug", sets: 2)]
        let after = [before[0], before[1], workout("dead-bug", sets: 1)]
        #expect(Proposal.lines(before: before, after: after, names: names).map { "\($0.mark.rawValue) \($0.text)" } == [
            "− Dumbbell Row (Single-Arm) + Dumbbell Bench Press",
            "~ Dead Bug, 1 set instead of 2",
            "= Bench Press and Deadlift as planned",
        ])
    }

    @Test func aSwapShowsWhatGoesAndWhatComes() {
        let before = [workout("bench-press", sets: 3, load: 140), workout("deadlift", sets: 3, load: 225)]
        let after = [workout("push-up", sets: 3), before[1]]
        #expect(Proposal.lines(before: before, after: after, names: names).map(\.mark) == [.removed, .added, .same])
    }
}

struct SpokenNumbersTests {
    @Test(arguments: [("two thirty five", 235.0), ("thirty minutes", 30), ("only four", 4), ("at 225", 225),
                      ("twenty-five reps", 25), ("two twenty", 220), ("one hundred", 100)])
    func numbersAreHeard(_ text: String, _ value: Double) {
        #expect(SpokenNumbers.values(in: text).contains(value))
    }

    @Test func bodyPartsAreFoundInTheWords() {
        #expect(BodyArea.mentioned(in: ["my", "shoulder", "hurts"]) == "shoulder")
        #expect(BodyArea.mentioned(in: ["lower", "back", "is", "tight"]) == "lower back")
        #expect(BodyArea.mentioned(in: ["only", "thirty", "minutes"]) == nil)
    }
}

extension SpokenNumbersTests {
    @Test func aWeightSaidInPartsIsOnlyTheWeight() {
        #expect(SpokenNumbers.values(in: "deadlifts were at two thirty five") == [235])
    }
}

extension SpokenNumbersTests {
    @Test(arguments: [("I only have thirty minutes today", 30), ("got 20 min", 20), ("only an hour", 60),
                      ("half an hour tops", 30), ("forty-five minutes", 45), ("1.5 hours", 90)])
    func minutesAreReadNextToTheirUnit(_ text: String, _ minutes: Int) {
        #expect(SpokenNumbers.minutes(in: text) == minutes)
    }
}
