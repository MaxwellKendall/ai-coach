import Foundation

/// The weekly review's contents (FIT-8), gathered from the store. Every number comes from `WeeklyReview`.
struct WeekReport {
    struct GoalRow: Identifiable {
        var goal: Goal
        var option: GoalOption
        var week: WeeklyReview.GoalWeek
        var start: Double
        var forecast: Double?
        var perWeek: Double
        var checkIn: WeeklyReview.CheckIn?
        var id: UUID { goal.id }
    }

    var days: Range<Date>
    /// This week of the program, 0-based, and how many weeks it has.
    var programWeek: Int?
    var programWeeks: Int?
    var end: Date?
    var numbers: WeeklyReview.Numbers
    var goals: [GoalRow]
    var alerts: [WeeklyReview.Alert]

    /// The last day of the week gets the review.
    static func isDue(_ date: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    @MainActor
    static func make(for date: Date = .now, profile: Profile?, goals: [Goal], entries: [LogEntry], planned: [PlannedActivity],
                     templates: [Template]) -> WeekReport {
        let days = WeeklyReview.days(of: date)
        let sets = Planner.loggedSets(entries, templates: templates)
        let meals = entries.filter { $0.kind == .meal }.map { (date: $0.timestamp, measurements: $0.measurements) }
        let sleep = Daily.totals(entries.filter { $0.kind == .sleep }.map { (date: $0.timestamp, measurements: $0.measurements) },
                                 metric: "sleep_h")
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        let protein = Daily.totals(meals, metric: "protein_g"), kcal = Daily.totals(meals, metric: "kcal")
        let workoutDays = planned.filter { $0.kind == .workout }.map(\.date)
        let numbers = WeeklyReview.numbers(week: days, workoutDays: workoutDays, sets: sets, protein: protein, kcal: kcal,
                                           sleep: sleep, weighIns: weighIns)
        // A session's note is on each of its sets; meal notes are the meal's name.
        var seen = Set<String>()
        let notes = entries.filter { $0.kind != .meal && !$0.note.isEmpty }.compactMap { entry -> (date: Date, text: String)? in
            let key = "\(Calendar.current.startOfDay(for: entry.timestamp)) \(entry.note)"
            return seen.insert(key).inserted ? (entry.timestamp, entry.note) : nil
        }
        let alerts = WeeklyReview.alerts(week: days, workoutDays: workoutDays, protein: protein, kcal: kcal, sleep: sleep,
                                         notes: notes, injured: profile?.injuredAreas ?? [])

        var rows: [GoalRow] = []
        var report = WeekReport(days: days, numbers: numbers, goals: [], alerts: alerts)
        if let profile, let weeks = profile.program, let start = profile.programStart {
            let current = max(0, min(weeks.count - 1, ProgramPlan.week(of: date, start: start)))
            let end = profile.targetDate ?? ProgramPlan.monday(weeks.count, start: start)
            report.programWeek = current
            report.programWeeks = weeks.count
            report.end = end
            for goal in goals where goal.status == .active {
                guard let option = GoalOption.all.first(where: { $0.metric == goal.metric }) else { continue }
                let first = goal.baseline ?? goal.target
                let now = GoalProgress.current(goal.metric, sets: sets, weighIns: weighIns, since: start) ?? first
                let before = GoalProgress.current(goal.metric, sets: sets.filter { $0.date < days.lowerBound },
                                                  weighIns: weighIns.filter { $0.date < days.lowerBound }, since: start) ?? first
                let pace = GoalProgress.pace(from: first, now: now, target: goal.target, week: current, weeks: weeks)
                let forecast = GoalProgress.forecast(from: first, now: now, started: start, today: date, end: end)
                rows.append(GoalRow(goal: goal, option: option,
                                    week: .init(from: before, to: now, target: goal.target, pace: pace), start: first,
                                    forecast: forecast, perWeek: GoalProgress.perWeek(now: now, target: goal.target, today: date, end: end),
                                    checkIn: WeeklyReview.checkIn(from: first, now: now, target: goal.target, pace: pace,
                                                                  forecast: forecast, step: option.step, week: current, weeks: weeks.count)))
            }
        }
        report.goals = rows
        return report
    }

    // MARK: Words

    /// "3 of 3 workouts. Squat up 9 lb."
    var headline: String {
        var parts: [String] = []
        if numbers.workoutsPlanned > 0 { parts.append("\(numbers.workoutsDone) of \(numbers.workoutsPlanned) workouts.") }
        let moved = goals.filter { $0.week.to != $0.week.from && ($0.week.to - $0.week.from) * ($0.goal.target - $0.start) > 0 }
            .max { progress($0) < progress($1) }
        if let moved { parts.append("\(Self.short(moved.option)) \(change(moved)).") }
        return parts.isEmpty ? "Your week" : parts.joined(separator: " ")
    }

    /// "Weight is behind. 2 goals to check in on."
    var subline: String {
        let behind = goals.filter { $0.week.pace == .behind }.map { Self.short($0.option) }
        let checks = goals.filter { $0.checkIn != nil }.count
        var parts: [String] = []
        if !behind.isEmpty {
            let names = WeeklyReview.list(behind)
            parts.append("\(names.prefix(1).uppercased() + names.dropFirst().lowercased()) \(behind.count == 1 ? "is" : "are") behind.")
        }
        if checks > 0 { parts.append("\(checks == 1 ? "1 goal" : "\(checks) goals") to check in on.") }
        if !alerts.isEmpty && parts.count < 2 { parts.append("\(WeeklyReview.count(alerts.count, "thing")) worth a look.") }
        return parts.isEmpty ? "Everything’s on pace." : parts.joined(separator: " ")
    }

    /// The facts the model writes from. Code says which went well and which need work, so the words can't flip them.
    var facts: [String] {
        var good: [String] = [], work: [String] = [], plain: [String] = []
        let (done, planned) = (numbers.workoutsDone, numbers.workoutsPlanned)
        if planned > 0 {
            if done >= planned { good.append("All \(planned) workouts done.") }
            else if done == 0 { work.append("No workouts logged this week (\(planned) planned).") }
            else { work.append("\(done) of \(planned) workouts done.") }
        }
        for row in goals {
            let toward = (row.week.to - row.week.from) * (row.goal.target - row.start) > 0
            let now = "now \(format(row.week.to, row.option)) of a \(format(row.goal.target, row.option)) \(row.goal.unit) goal"
            if toward { good.append("\(row.option.name) \(change(row)) this week, \(now).") }
            if row.week.pace == .behind { work.append("\(row.option.name) is behind the plan's pace, \(now).") }
        }
        if let protein = numbers.protein { plain.append("Protein averaged \(Int(protein.rounded())) g a day.") }
        if let sleep = numbers.sleep { plain.append("Sleep averaged \(Coach.number(sleep)) hours a night.") }
        work += alerts.map { "\($0.title)." }
        return good.map { "Went well: \($0)" } + work.map { "Needs work: \($0)" } + plain.map { "Also: \($0)" }
    }

    private func progress(_ row: GoalRow) -> Double {
        abs(row.week.to - row.week.from) / max(abs(row.goal.target - row.start), 1)
    }

    /// "up 9 lb", "down 0.6 lb", "up 1 rep".
    func change(_ row: GoalRow) -> String {
        let delta = row.week.to - row.week.from
        let unit = row.goal.unit == "reps" && abs(delta) == 1 ? "rep" : row.goal.unit
        return "\(delta < 0 ? "down" : "up") \(format(abs(delta), row.option)) \(unit)"
    }

    func format(_ value: Double, _ option: GoalOption) -> String {
        Coach.number(option.measure == .body ? value : value.rounded())
    }

    static func short(_ option: GoalOption) -> String {
        switch option.id {
        case "pullups": "Pull-ups"
        case "pushups": "Push-ups"
        default: option.id.prefix(1).uppercased() + option.id.dropFirst()
        }
    }
}
