import Foundation

/// FIT-336: a coach programming a client's weeks from the phone: a week copied forward (with or without +5 lb a week on
/// the main lifts), a deload, and a ready-made program. Plans are day key ("yyyy-MM-dd") → that day's plan rows.
enum ClientWeek {
    typealias Days = [String: [SyncUnits.PlanRow]]

    /// The days of the week from `sunday` that have a plan.
    static func days(_ units: [String: String], sunday: Date, calendar: Calendar = .current) -> Days {
        var days: Days = [:]
        for offset in 0..<7 {
            let key = SyncUnits.day(calendar.date(byAdding: .day, value: offset, to: sunday)!, calendar: calendar)
            let rows = ClientDay.plan(units, key)
            if !rows.isEmpty { days[key] = rows }
        }
        return days
    }

    /// A week copied 1…`weeks` weeks on, each a fresh copy pinned as a coach's change. `progress` adds 5 lb a week to the
    /// main lifts' weight, as the dashboard's Send Program does (FIT-131).
    static func repeated(_ week: Days, weeks: Int, progress: Bool, calendar: Calendar = .current) -> Days {
        var out: Days = [:]
        for n in 1...max(1, weeks) {
            for (key, rows) in week {
                guard let date = SyncUnits.date(ofKey: "plan#\(key)", calendar: calendar),
                      let target = calendar.date(byAdding: .day, value: 7 * n, to: date) else { continue }
                var copy = ClientDay.shifted(rows, to: target, fresh: true, calendar: calendar)
                if progress {
                    copy = copy.map { row in
                        guard row.main, let index = row.targets.firstIndex(where: { ["load_lb", "load_lb_hand"].contains($0.metric) }) else { return row }
                        var row = row
                        row.targets[index].value += 5 * Double(n)
                        row.adjustedReason = "+\(5 * n) lb"
                        return row
                    }
                }
                out[SyncUnits.day(target, calendar: calendar)] = copy
            }
        }
        return out
    }

    /// A deload day: the generator's own deload (TrainingGenerator.deloadSets, deloadLoad, deloadRPE; fitness-planner
    /// CLAUDE.md "Deload"): fewer sets, lighter, easier. Warm-ups and runs stay as they are.
    static func deloaded(_ rows: [SyncUnits.PlanRow]) -> [SyncUnits.PlanRow] {
        rows.map { row in
            guard row.note != TrainingGenerator.warmupNote, !Running.runs.contains(row.template ?? "") else { return row }
            var row = row
            for index in row.targets.indices {
                switch row.targets[index].metric {
                case "sets": row.targets[index].value = max(1, (row.targets[index].value * TrainingGenerator.deloadSets).rounded())
                case "load_lb", "load_lb_hand":
                    row.targets[index].value = max(5, (row.targets[index].value * TrainingGenerator.deloadLoad / 5).rounded() * 5)
                case "rpe": row.targets[index].value = min(row.targets[index].value, TrainingGenerator.deloadRPE)
                default: break
                }
            }
            row.adjustedReason = "Deload week: lighter"
            row.pinned = true
            return row
        }
    }

    /// Every week of a ready-made program from `start`, as the client's own app would plan it (Planner.trainingWeek,
    /// FIT-230), from their profile and what they've logged. The days are theirs when they fit the program, else the
    /// program's nearest.
    @MainActor static func program(_ ready: ReadyProgram, from start: Date, profile: SyncUnits.ProfileBody?, logs: [SyncUnits.LogRow],
                        templates: [Template], calendar: Calendar = .current) -> Days {
        let theirs = profile?.trainingDays ?? []
        let days = ready.days.contains(theirs.count) ? theirs : ReadyProgram.days(for: ready.days(nearest: theirs.count))
        let age = profile?.age ?? 35
        let settings = TrainingSettings(
            age: age, daysPerWeek: days.count, sessionMinutes: ready.minutes, trainingDays: Week.ordered(days),
            workoutTime: profile?.workoutTime ?? 420, equipment: Set(profile?.equipment ?? Profile.allEquipment),
            injuredAreas: BodyArea.muscles(for: profile?.injuredAreas ?? []), avoidExercises: Set(profile?.avoidExercises ?? []),
            maxWeeklySets: profile?.maxWeeklySets ?? 60, style: profile?.style ?? .powerbuilding, warmups: profile?.warmups ?? true,
            deloadEveryWeeks: profile?.deloadEveryWeeks, starts: profile?.starts ?? [], bodyWeight: profile?.weightLb)
        let weeks = ProgramPlan.weeks(count: ready.weeks, deloadEvery: profile?.deloadEveryWeeks ?? AgeTier.of(age: age).deloadEveryWeeks)
            .map { ProgramWeek(phase: .base, kind: $0.kind == .deload ? .deload : .base, travel: $0.travel) }
        let bySlug = Dictionary(templates.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let history = logs.filter { $0.kind == .workout }.compactMap { row -> LoggedSet? in
            guard let slug = row.template, let template = bySlug[slug] else { return nil }
            return LoggedSet(date: row.at, exercise: slug, pattern: template.values("movement_pattern").first, measurements: row.measurements)
        }.sorted { $0.date < $1.date }
        let catalog = Planner.catalog(templates)
        var out: Days = [:]
        for index in 0..<ready.weeks {
            let monday = calendar.date(byAdding: .day, value: 7 * index, to: Week.start(of: start, calendar: calendar))!
            let workouts = ready.week(startingOn: monday, start: start, settings: settings, catalog: catalog, history: history,
                                      program: weeks, calendar: calendar).workouts
            for (order, workout) in workouts.enumerated() {
                let key = SyncUnits.day(workout.date, calendar: calendar)
                out[key, default: []].append(SyncUnits.PlanRow(
                    id: UUID(), kind: .workout, at: workout.date + TimeInterval(order), slot: workout.session, template: workout.exercise,
                    targets: workout.targets, note: workout.note ?? "", adjustedReason: workout.adjustedReason, group: workout.group,
                    main: workout.main, pinned: true))
            }
        }
        return out
    }
}
