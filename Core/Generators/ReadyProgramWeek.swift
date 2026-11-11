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
/// FIT-277: each change says why, from the numbers, on the row's `adjustedReason` (`Why`).
extension ReadyProgram {
    static let firstTimeNote = "First time: pick a weight you could lift 2–3 more times."

    /// FIT-277: why an exercise changed from last time, one line each: "+5 lb: you hit every rep".
    enum Why: Equatable, Sendable {
        case hitEveryRep(step: Double, unit: String)
        case topOfRange(step: Double, unit: String)
        case missedTwice(load: Double, unit: String)
        case held(fewest: Double, planned: Double)
        case oneMoreRep(reps: Double)
        case nextRung
        case longerHold(seconds: Double)
        case newWave(step: Double)
        case deload

        var text: String {
            switch self {
            case let .hitEveryRep(step, unit): "+\(Coach.number(step)) \(unit): you hit every rep"
            case let .topOfRange(step, unit): "+\(Coach.number(step)) \(unit): top of the range on every set"
            case let .missedTwice(load, unit): "Down to \(Coach.number(load)) \(unit): short of the reps twice"
            case let .held(fewest, planned): "Held: \(Coach.number(fewest)) of \(Coach.number(planned)) reps on a set"
            case let .oneMoreRep(reps): "One more rep: \(Coach.number(reps)) a set"
            case .nextRung: "Next step: top of the range on every set"
            case let .longerHold(seconds): "+5 s: \(Coach.number(seconds)) s a set"
            case let .newWave(step): "+\(Coach.number(step)) lb on the training max: a new wave"
            case .deload: "Deload week: lighter, to recover"
            }
        }

        /// Whether a row's reason is one of these, to show it under the lift (other reasons, like "edited", aren't).
        static func explains(_ reason: String?) -> Bool {
            guard let reason else { return false }
            return ["+", "Down to ", "Held: ", "One more rep: ", "Next step: ", "Deload week: "].contains { reason.hasPrefix($0) }
        }
    }

    func week(startingOn monday: Date, start: Date, settings: TrainingSettings, catalog: [Exercise],
              history: [LoggedSet], program: [ProgramWeek], calendar: Calendar = .current) -> TrainingWeek {
        let monday = Week.start(of: monday, calendar: calendar)
        let index = ProgramPlan.week(of: monday, start: start, calendar: calendar)
        // FIT-325: nothing after its last week; Today offers the recap and the next program instead.
        guard index < weeks else { return TrainingWeek(workouts: [], deload: false, warnings: []) }
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
                if item.wave == true {
                    let rows = wave(item, on: date, session: session.name, week: index, light: lightWeeks, allowed: allowed,
                                    catalog: byslug, starts: settings.starts)
                    if let first = rows.first, first.main, let load = first.target("load_lb"), load >= 95,
                       let warmup = TrainingGenerator.warmup(for: first, settings: settings, tier: AgeTier.of(age: settings.age)) {
                        workouts.append(warmup)
                    }
                    workouts += rows
                    continue
                }
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

        // FIT-425: a lift in two items (Push/Pull/Legs' 4 × 5 press and its 3 × 8) progresses each from its own
        // sessions: the ones whose reps look like this item's range, so a set of 8 isn't read as a missed 4 × 5.
        let ownSessions = { (slug: String) in
            Self.sessions(of: slug, history, calendar: calendar).filter { session in
                let reps = session.compactMap { $0.value("reps") }
                return item.seconds != nil || reps.isEmpty || (reps.max()! >= low - 2 && reps.max()! <= high + 2)
            }
        }
        // A ladder carries on from its most recent rung, and climbs one once the top of the range is done on every set.
        var last = ownSessions(slug).last ?? []
        var climbed = false
        if item.ladder != nil {
            if let latest = history.last(where: { choices.contains($0.exercise) })?.exercise { slug = latest }
            last = ownSessions(slug).last ?? []
            if Self.done(last, metric: "reps", value: high, sets: item.sets),
               let rung = choices.firstIndex(of: slug), choices.indices.contains(rung + 1) {
                slug = choices[rung + 1]
                last = []
                climbed = true
            }
        }
        let exercise = catalog[slug]!
        var targets = [Measurement(metric: "sets", value: Double(sets), unit: "sets")]
        var note: String?
        var why: Why? = light && !last.isEmpty ? .deload : climbed ? .nextRung : nil

        if item.seconds != nil {
            let held = last.compactMap { $0.value("duration_s") }.min()
            let seconds = held.map { min(max($0 + 5, low), high) } ?? low
            if !light, let held, seconds > held { why = .longerHold(seconds: seconds) }
            targets.append(Measurement(metric: "duration_s", value: seconds, unit: "s"))
        } else {
            let perHand = !exercise.equipment.isDisjoint(with: ["dumbbells", "kettlebells"]) && !exercise.equipment.contains("barbell")
            let metric = perHand ? "load_lb_hand" : "load_lb"
            let step = item.step ?? 5
            let unit = perHand ? "lb a hand" : "lb"
            let lastLoad = last.compactMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }.max()
            var reps = low
            var load = lastLoad ?? starts.first { $0.exercise == slug }.flatMap { Self.fromRecent(item, $0)?.start } ?? item.start
            if !last.isEmpty {
                let fewest = last.compactMap { $0.value("reps") }.min() ?? 0
                if low == high {
                    if Self.done(last, metric: "reps", value: low, sets: item.sets) {
                        load = load.map { $0 + step }
                        if load != nil, !light { why = .hitEveryRep(step: step, unit: unit) }
                    } else if let lastLoad, let previous = ownSessions(slug).dropLast().last,
                              !Self.done(previous, metric: "reps", value: low, sets: item.sets),
                              (previous.compactMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }.max() ?? 0) >= lastLoad {
                        // Two misses in a row: back off 10% and build again.
                        load = Self.round(lastLoad * 0.9, perHand: perHand)
                        if !light { why = .missedTwice(load: load!, unit: unit) }
                    } else if !light {
                        why = .held(fewest: fewest, planned: low)
                    }
                } else if Self.done(last, metric: "reps", value: high, sets: item.sets), let current = load {
                    load = current + step
                    if !light { why = .topOfRange(step: step, unit: unit) }
                } else {
                    reps = min(max(fewest + 1, low), high)
                    if !light, reps > fewest { why = .oneMoreRep(reps: reps) }
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
                              adjustedReason: why?.text, group: item.group, main: item.main ?? false)
    }

    /// FIT-321: a lift's sets by the week of its 3-week cycle, as percentages of a training max, then 5 × 5 at the
    /// day's first percentage; one row a set, which Today shows as one lift.
    static let waves: [[(percent: Double, reps: Double)]] = [
        [(0.65, 5), (0.75, 5), (0.85, 5)],
        [(0.70, 3), (0.80, 3), (0.90, 3)],
        [(0.75, 5), (0.85, 3), (0.95, 1)],
    ]

    /// The training max: 90% of the estimated max from their recent set of the lift, else the program's start; up the
    /// item's step (5 lb upper body, 10 lower) after each cycle. Deload weeks don't count toward a cycle and stay light:
    /// the first week's three sets, lighter, without the 5 × 5.
    private func wave(_ item: Item, on date: Date, session: String, week index: Int, light: Set<Int>, allowed: Set<String>,
                      catalog: [String: Exercise], starts: [StartingSet]) -> [PlannedWorkout] {
        guard let slug = item.choices.first(where: { allowed.contains($0) && catalog[$0] != nil }) else { return [] }
        let step = item.step ?? 5
        let recent = starts.first { $0.exercise == slug }.flatMap { set -> Double? in
            guard let load = set.value("load_lb"), let reps = set.value("reps") else { return nil }
            return TrainingGenerator.roundTo5(ProgramPlan.estimatedMax(load: load, reps: reps) * 0.9)
        }
        guard let base = recent ?? item.start else { return [] }
        let done = (0..<max(0, index)).filter { !light.contains($0) }.count
        let cycle = done / 3, trainingMax = base + Double(cycle) * step
        let deload = light.contains(index)
        let sets = deload ? Self.waves[0] : Self.waves[done % 3]
        let why: Why? = deload ? .deload : cycle > 0 && done % 3 == 0 ? .newWave(step: step) : nil
        func row(_ percent: Double, _ reps: Double, count: Int) -> PlannedWorkout {
            let load = TrainingGenerator.roundTo5(trainingMax * percent * (deload ? TrainingGenerator.deloadLoad : 1))
            return PlannedWorkout(date: date, session: session, exercise: slug,
                                  targets: [Measurement(metric: "sets", value: Double(count), unit: "sets"),
                                            Measurement(metric: "reps", value: reps, unit: "reps"),
                                            Measurement(metric: "load_lb", value: load, unit: "lb")],
                                  adjustedReason: why?.text, main: item.main ?? false)
        }
        return sets.map { row($0.percent, $0.reps, count: 1) } + (deload ? [] : [row(sets[0].percent, 5, count: 5)])
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
