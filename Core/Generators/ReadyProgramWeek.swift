import Foundation

/// FIT-230: a ready-made program's week. Its sessions go in turn on the training days, carrying on from last week, and
/// each exercise is dosed from how it went last time by its rule:
/// - one rep count (3 × 5): all the reps done adds the step (5 lb, 10 on deadlift); two misses in a row take 10% off;
/// - a rep range (3 × 8–12): one more rep a session, and at the top on every set, the step with the reps back down;
/// - a ladder: at the top of the range on every set, the next exercise, from the bottom of the range;
/// - a hold: 5 s more a session, up to the range's top.
/// The first time, the program's starting load and the bottom of the range, or (FIT-281) a little under a recent set
/// they gave (`fromRecent`). Deload weeks (`ProgramPlan.weeks`) cut the
/// sets and loads as `TrainingGenerator` does, and their sessions don't count when the next week progresses.
extension ReadyProgram {
    static let firstTimeNote = "First time: pick a weight you could lift 2–3 more times."

    func week(startingOn monday: Date, start: Date, settings: TrainingSettings, catalog: [Exercise],
              history: [LoggedSet], program: [ProgramWeek], calendar: Calendar = .current) -> TrainingWeek {
        let monday = Week.start(of: monday, calendar: calendar)
        let index = ProgramPlan.week(of: monday, start: start, calendar: calendar)
        let light = program.indices.contains(index) && program[index].kind == .deload
        let lightWeeks = Set(program.indices.filter { program[$0].kind == .deload })
        let past = history.filter { set in
            set.date < monday && !lightWeeks.contains(ProgramPlan.week(of: set.date, start: start, calendar: calendar))
        }
        let byslug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let allowed = Set(catalog.filter { TrainingGenerator.allows($0, settings) }.map(\.slug))

        let days = Week.ordered(settings.trainingDays)
        var slots = days.map { Week.date($0, in: monday, calendar: calendar) }
        var before = 0
        if index > 0 {
            before = Self.sessions(firstWeekFrom: start, days: days, calendar: calendar).count + (index - 1) * days.count
        } else if index == 0 {
            slots = Self.sessions(firstWeekFrom: start, days: days, calendar: calendar)
        } else {
            slots = []
        }

        var workouts: [PlannedWorkout] = []
        for (offset, day) in slots.enumerated() {
            let session = sessions[(before + offset) % sessions.count]
            let date = calendar.date(byAdding: .minute, value: settings.workoutTime, to: calendar.startOfDay(for: day))!
            for item in session.exercises {
                guard let row = dose(item, on: date, session: session.name, allowed: allowed, catalog: byslug, starts: settings.starts,
                                     history: past, light: light, calendar: calendar) else { continue }
                if row.main, let load = row.target("load_lb"), load >= 95,
                   let warmup = TrainingGenerator.warmup(for: row, settings: settings, tier: AgeTier.of(age: settings.age)) {
                    workouts.append(warmup)
                }
                workouts.append(row)
            }
        }
        return TrainingWeek(workouts: workouts, deload: light,
                            warnings: light ? TrainingGenerator.weekWarnings(program: nil, deload: true) : [])
    }

    /// The first week's session days: the training days from the start on, or the start day itself when none are left,
    /// so a program started on a Saturday still has a session to do.
    static func sessions(firstWeekFrom start: Date, days: [Int], calendar: Calendar = .current) -> [Date] {
        let monday = Week.start(of: start, calendar: calendar)
        let first = calendar.startOfDay(for: start)
        let left = days.map { Week.date($0, in: monday, calendar: calendar) }.filter { $0 >= first }
        return left.isEmpty ? [first] : left
    }

    private func dose(_ item: Item, on date: Date, session: String, allowed: Set<String>, catalog: [String: Exercise],
                      starts: [StartingSet], history: [LoggedSet], light: Bool, calendar: Calendar) -> PlannedWorkout? {
        let choices = item.choices.filter { allowed.contains($0) && catalog[$0] != nil }
        guard var slug = choices.first else { return nil }
        let range = (item.seconds ?? item.reps ?? [10]).sorted()
        let low = Double(range.first!), high = Double(range.last!)
        let sets = light ? max(1, Int((Double(item.sets) * TrainingGenerator.deloadSets).rounded())) : item.sets

        // A ladder carries on from its most recent rung, and climbs one once the top of the range is done on every set.
        var last = Self.sessions(of: slug, history, calendar: calendar).last ?? []
        if item.ladder != nil {
            if let latest = history.last(where: { choices.contains($0.exercise) })?.exercise { slug = latest }
            last = Self.sessions(of: slug, history, calendar: calendar).last ?? []
            if Self.done(last, metric: "reps", value: high, sets: item.sets),
               let rung = choices.firstIndex(of: slug), choices.indices.contains(rung + 1) {
                slug = choices[rung + 1]
                last = []
            }
        }
        let exercise = catalog[slug]!
        var targets = [Measurement(metric: "sets", value: Double(sets), unit: "sets")]
        var note: String?

        if item.seconds != nil {
            let held = last.compactMap { $0.value("duration_s") }.min()
            targets.append(Measurement(metric: "duration_s", value: held.map { min(max($0 + 5, low), high) } ?? low, unit: "s"))
        } else {
            let perHand = !exercise.equipment.isDisjoint(with: ["dumbbells", "kettlebells"]) && !exercise.equipment.contains("barbell")
            let metric = perHand ? "load_lb_hand" : "load_lb"
            let step = item.step ?? 5
            let lastLoad = last.compactMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }.max()
            var reps = low
            var load = lastLoad ?? starts.first { $0.exercise == slug }.flatMap { Self.fromRecent(item, $0)?.start } ?? item.start
            if !last.isEmpty {
                let fewest = last.compactMap { $0.value("reps") }.min() ?? 0
                if low == high {
                    if Self.done(last, metric: "reps", value: low, sets: item.sets) {
                        load = load.map { $0 + step }
                    } else if let lastLoad, let previous = Self.sessions(of: slug, history, calendar: calendar).dropLast().last,
                              !Self.done(previous, metric: "reps", value: low, sets: item.sets),
                              (previous.compactMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }.max() ?? 0) >= lastLoad {
                        // Two misses in a row: back off 10% and build again.
                        load = Self.round(lastLoad * 0.9, perHand: perHand)
                    }
                } else if Self.done(last, metric: "reps", value: high, sets: item.sets), let current = load {
                    load = current + step
                } else {
                    reps = min(max(fewest + 1, low), high)
                }
            } else if item.start != nil, !light {
                note = Self.firstTimeNote
            }
            targets.append(Measurement(metric: "reps", value: reps, unit: "reps"))
            if let value = load, exercise.isLoaded {
                let value = light ? Self.round(value * TrainingGenerator.deloadLoad, perHand: perHand) : value
                targets.append(Measurement(metric: metric, value: value, unit: perHand ? "lb/hand" : "lb"))
            }
        }
        return PlannedWorkout(date: date, session: session, exercise: slug, targets: targets, note: note,
                              group: item.group, main: item.main ?? false)
    }

    /// Every working set planned was done, at `value` or more.
    private static func done(_ sets: [LoggedSet], metric: String, value: Double, sets planned: Int) -> Bool {
        sets.count >= planned && sets.allSatisfy { ($0.value(metric) ?? 0) >= value }
    }

    /// An exercise's logged sets, one array per day, oldest first.
    private static func sessions(of slug: String, _ history: [LoggedSet], calendar: Calendar) -> [[LoggedSet]] {
        Dictionary(grouping: history.filter { $0.exercise == slug }) { calendar.startOfDay(for: $0.date) }
            .sorted { $0.key < $1.key }.map(\.value)
    }

    /// To the nearest 5 lb on a bar or machine, 2.5 lb on a dumbbell.
    private static func round(_ load: Double, perHand: Bool) -> Double {
        perHand ? (load / 2.5).rounded() * 2.5 : TrainingGenerator.roundTo5(load)
    }
}
