import SwiftUI
import Charts

/// One program goal (FIT-8), a card in the Goals deck: now → target and the pace, the logged line against the plan
/// with a forecast at the current rate, what it needs each week, the set behind it, and the target.
struct GoalCard: View {
    let goal: Goal
    let option: GoalOption
    /// Empty without a program of the app's (FIT-342): a coach's client, whose card runs from the goal's own start.
    let weeks: [ProgramWeek]
    /// The program's first day and its target date, or without one the goal's own (GoalProgress.span).
    let start: Date
    let end: Date
    /// FIT-278: the goal's own date when it has one, else the program's.
    private var due: Date { goal.deadline ?? end }
    /// This week of the program, 0-based.
    let current: Int
    let sets: [LoggedSet]
    let weighIns: [DatedValue]
    /// The next planned workout with the goal's exercise.
    let next: Date?
    let setTarget: (Double) -> Void
    /// FIT-343: record a test toward it. FIT-346: change its target and date, or drop it.
    let update: () -> Void
    let change: () -> Void

    /// FIT-342: a card with a date to aim at: the program's, or the goal's own. Without one there's no pace, plan line
    /// or forecast, only now → target and the trend.
    private var dated: Bool { !weeks.isEmpty || goal.deadline != nil }

    var body: some View {
        ScrollView { content }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(.rect(cornerRadius: 24))
            .cardBackground()
            .accessibilityElement(children: .contain)
    }

    var content: some View {
        let logged = GoalProgress.current(goal.metric, sets: sets, weighIns: weighIns, since: start)
        let from = goal.baseline ?? logged ?? goal.target
        let now = GoalProgress.standing(goal.metric, logged: logged, from: from)
        let trend = GoalProgress.standingTrend(goal.metric, GoalProgress.trend(goal.metric, sets: sets, weighIns: weighIns, since: start), from: from)
        let pace: GoalProgress.Pace? = goal.deadline == nil && !weeks.isEmpty
            ? GoalProgress.pace(goal.metric, from: from, now: now, target: goal.target, week: current, weeks: weeks)
            : GoalProgress.pace(goal.metric, from: from, now: now, target: goal.target, started: start, today: .now, by: dated ? due : nil)
        let forecast = dated ? GoalProgress.forecast(from: from, now: now, target: goal.target, started: start, today: .now, end: due) : nil
        let lines = GoalChart.Lines(plan: plan(from: from), logged: [DatedValue(date: start, value: from)] + trend,
                                    forecast: forecast, target: goal.target, start: start,
                                    // A date already past when the card starts can't end the chart: that range runs backwards.
                                    end: due > start ? due : end, format: option.format, dated: dated)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(option.name).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let pace { PaceChip(pace: pace) }
                Menu {
                    Button("Update", systemImage: "plus.circle", action: update)
                    Button("Change Target or Date", systemImage: "pencil", action: change)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 36, height: 28).contentShape(.rect)
                }
                .accessibilityLabel("More for this goal")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(format(now)).contentTransition(.numericText())
                Text("→ \(format(goal.target))").foregroundStyle(.secondary).contentTransition(.numericText())
                if !option.shownUnit.isEmpty { Text(option.shownUnit).font(.title3).foregroundStyle(.secondary) }
            }
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.top, 6)
            Text(line(from: from, now: now)).font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            Button(action: update) {
                Label("Update", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .padding(.top, 12)
            .accessibilityHint(option.measure == .body ? "Log a weigh-in" : "Record a test: a max, reps or a timed run")
            details(lines, from: from, now: now, forecast: forecast)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
    }

    private func details(_ lines: GoalChart.Lines, from: Double, now: Double, forecast: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GoalChart(lines: lines)
                .frame(height: 150)
                .padding(.top, 18)
                .accessibilityLabel("\(option.name) from \(format(from)) to \(format(now)), goal \(format(goal.target))\(dated ? " by \(day(due))" : "")")
            HStack(spacing: 14) {
                legend("Logged", StrokeStyle(lineWidth: 2), .primary)
                if !lines.plan.isEmpty { legend("Plan", StrokeStyle(lineWidth: 2, dash: [3, 3]), Color(.systemGray3)) }
                if forecast != nil { legend("At this rate", StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]), .secondary) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 10)
            VStack(spacing: 0) {
                ForEach(facts(from: from, now: now, forecast: forecast), id: \.0) { fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.0).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(fact.1).fontWeight(.semibold).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .padding(.top, 8)
            HStack {
                Text("Target").foregroundStyle(.secondary)
                Spacer(minLength: 24)
                Nudge(label: "\(format(goal.target)) \(option.shownUnit)",
                      lessLabel: option.measure == .time ? "A faster target" : "Lower the target",
                      moreLabel: option.measure == .time ? "A slower target" : "Raise the target",
                      less: { setTarget(goal.target - option.step) }, more: { setTarget(goal.target + option.step) })
                    .frame(maxWidth: 220)
            }
            .padding(.top, 12)
        }
    }

    private func legend(_ title: String, _ style: StrokeStyle, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: style).frame(width: 14, height: 2)
            Text(title)
        }
    }

    /// The program's line for the goal: from where it started to the target, flat through deloads and travel, up to
    /// the goal's date.
    /// FIT-342: without program weeks, a straight line to the goal's date, or none without a date.
    private func plan(from: Double) -> [DatedValue] {
        guard !weeks.isEmpty else {
            return goal.deadline == nil ? [] : [DatedValue(date: start, value: from), DatedValue(date: due, value: goal.target)]
        }
        return [DatedValue(date: start, value: from)] + weeks.indices.map { index in
            DatedValue(date: min(ProgramPlan.monday(index + 1, start: start), end),
                       value: ProgramPlan.expected(from: from, target: goal.target, at: index, weeks: weeks))
        }.filter { $0.date <= due }
    }

    /// "29 lb up since Aug 10 · 45% there".
    private func line(from: Double, now: Double) -> String {
        let moved = abs(now - from)
        let percent = Int((GoalProgress.fraction(goal.metric, from: from, now: now, target: goal.target) * 100).rounded())
        guard moved > 0 else { return "Started at \(format(from)) on \(day(start))" }
        if option.measure == .time {
            return "\(Running.clock(moved)) \(now < from ? "faster" : "slower") since \(day(start)) · \(percent)% there"
        }
        let direction = (now < from) ? "down" : "up"
        return "\(Coach.number(moved)) \(goal.unit) \(direction) since \(day(start)) · \(percent)% there"
    }

    private func facts(from: Double, now: Double, forecast: Double?) -> [(String, String)] {
        var facts: [(String, String)] = []
        if let forecast { facts.append(("At this rate", outlook(from: from, lands: forecast))) }
        let perWeek = GoalProgress.perWeek(now: now, target: goal.target, today: .now, end: due)
        let there = GoalProgress.fraction(goal.metric, from: from, now: now, target: goal.target) >= 1
        let needed = option.measure == .time ? "\(Running.clock(abs(perWeek))) faster a week" : "\(Coach.number(abs(perWeek))) \(goal.unit) a week"
        if there || dated { facts.append(("To get there", there ? "Already there" : needed)) }
        if option.measure == .time {
            // FIT-179: the run behind the predicted time.
            if let run = GoalProgress.best(goal.metric, sets: sets, since: start), let meters = run.value("distance_m"), let seconds = run.value("duration_s") {
                facts.append(("Best run", "\(Running.distance(meters)) in \(Running.clock(seconds)) · \(day(run.date))"))
            } else {
                facts.append(("Predicted from", "Your runs once you log one"))
            }
        } else if option.measure == .body {
            if let last = weighIns.filter({ $0.date >= start }).max(by: { $0.date < $1.date }) {
                facts.append(("Last weigh-in", "\(Coach.number(last.value)) · \(day(last.date))"))
            }
        } else if let best = GoalProgress.best(goal.metric, sets: sets, since: start), let reps = best.value("reps") {
            let set = best.value("load_lb").map { "\(Coach.number($0)) × \(Coach.number(reps))" } ?? Coach.number(reps)
            facts.append(("Best set", "\(set) · \(day(best.date))"))
        }
        if let next { facts.append(("Next chance", chance(next))) }
        return facts
    }

    /// FIT-278: "12 lb short of 250 by Jan 16", "15 lb past 250 by Jan 16", or for a race time "0:45 slower than 25:00".
    private func outlook(from: Double, lands: Double) -> String {
        let gap = GoalProgress.shortfall(goal.metric, from: from, lands: lands, target: goal.target)
        let by = "\(format(goal.target)) by \(day(due))"
        if option.measure == .time {
            guard Int(abs(gap).rounded()) > 0 else { return "Right on \(by)" }
            return "\(Running.clock(abs(gap))) \(gap > 0 ? "slower" : "faster") than \(by)"
        }
        let amount = format(abs(gap))
        guard amount != format(0) else { return "Right on \(by)" }
        return "\(amount) \(goal.unit) \(gap > 0 ? "short of" : "past") \(by)"
    }

    /// Maxes and reps in whole numbers, body weight to a tenth, a race time as a clock.
    private func format(_ value: Double) -> String { option.format(value) }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    /// "Today", "Monday", "Mon, Oct 12".
    private func chance(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Behind is filled, ahead outlined, on pace quiet.
struct PaceChip: View {
    let pace: GoalProgress.Pace

    var body: some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(pace == .behind ? Color(.systemBackground) : .primary)
            .background {
                switch pace {
                case .behind: Capsule().fill(.primary)
                case .ahead: Capsule().strokeBorder(.primary, lineWidth: 1.5)
                default: Capsule().fill(Color.fill)
                }
            }
    }

    var label: String {
        switch pace {
        case .starting: "Starting"
        case .behind: "Behind"
        case .onPace: "On pace"
        case .ahead: "Ahead"
        }
    }
}

/// Logged values against the plan line, with a dotted forecast to the target date.
struct GoalChart: View {
    struct Lines {
        var plan: [DatedValue]
        var logged: [DatedValue]
        var forecast: Double?
        var target: Double
        var start: Date
        var end: Date
        var format: (Double) -> String = { Coach.number($0) }
        /// FIT-342: false for a goal with no date, whose target has no day to sit on.
        var dated = true
    }

    let lines: Lines
    private let today = Date.now

    var body: some View {
        let values = lines.plan.map(\.value) + lines.logged.map(\.value) + [lines.target]
        let low = values.min()!, high = values.max()!
        let pad = max(high - low, 1) * 0.1
        let domain = (low - pad)...(high + pad)
        let last = lines.logged.last!
        Chart {
            ForEach(lines.plan, id: \.self) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Line", "Plan"))
                    .foregroundStyle(Color(.systemGray3))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            if let forecast = lines.forecast {
                ForEach([last, DatedValue(date: lines.end, value: min(domain.upperBound, max(domain.lowerBound, forecast)))], id: \.self) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Line", "Forecast"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                }
            }
            ForEach(lines.logged, id: \.self) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Line", "Logged"))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Date", point.date), y: .value("Value", point.value)).foregroundStyle(Color.primary).symbolSize(20)
            }
            RuleMark(y: .value("Goal", lines.target)).foregroundStyle(Color(.separator)).lineStyle(StrokeStyle(lineWidth: 1))
                // Above the line either way: below it, a falling goal's label ran into the start date.
                .annotation(position: .top, alignment: .leading, spacing: 4) {
                    Text("Goal \(lines.format(lines.target))").font(.caption2).foregroundStyle(.secondary)
                }
            if lines.dated {
                PointMark(x: .value("Date", lines.end), y: .value("Value", lines.target))
                    .symbol {
                        Circle().fill(Color.fill)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: 2))
                            .frame(width: 9, height: 9)
                    }
            }
        }
        .chartXScale(domain: lines.start...lines.end)
        .chartYScale(domain: domain)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: dates) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top) {
                    Text(dates[value.index] == today ? "Today" : dates[value.index].formatted(.dateTime.month(.abbreviated).day()))
                }
            }
        }
    }

    /// Start, today and the target date. Today is left out when it's too near either end to have its own label.
    private var dates: [Date] {
        let span = lines.end.timeIntervalSince(lines.start)
        let along = today.timeIntervalSince(lines.start) / max(span, 1)
        return (0.2...0.8).contains(along) ? [lines.start, today, lines.end] : [lines.start, lines.end]
    }
}
