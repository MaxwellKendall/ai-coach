import SwiftUI
import Charts

/// One program goal (FIT-8): now → target, a sparkline against the plan and the pace. Opened in place: the plan
/// line, a forecast at the current rate, what it needs each week, the set behind it, and the target.
struct GoalCard: View {
    let goal: Goal
    let option: GoalOption
    let weeks: [ProgramWeek]
    /// The program's first day and its target date.
    let start: Date
    let end: Date
    /// This week of the program, 0-based.
    let current: Int
    let sets: [LoggedSet]
    let weighIns: [DatedValue]
    /// The next planned workout with the goal's exercise.
    let next: Date?
    let open: Bool
    let toggle: () -> Void
    let setTarget: (Double) -> Void

    var body: some View {
        let logged = GoalProgress.current(goal.metric, sets: sets, weighIns: weighIns, since: start)
        let from = goal.baseline ?? logged ?? goal.target
        let now = logged ?? from
        let trend = GoalProgress.trend(goal.metric, sets: sets, weighIns: weighIns, since: start)
        let pace = GoalProgress.pace(from: from, now: now, target: goal.target, week: current, weeks: weeks)
        let forecast = GoalProgress.forecast(from: from, now: now, started: start, today: .now, end: end)
        let lines = GoalChart.Lines(plan: plan(from: from), logged: [DatedValue(date: start, value: from)] + trend,
                                    forecast: forecast, target: goal.target, start: start, end: end)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(option.name).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        PaceChip(pace: pace)
                    }
                    HStack(alignment: .bottom) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(format(now)).contentTransition(.numericText())
                            Text("→ \(format(goal.target))").foregroundStyle(.secondary).contentTransition(.numericText())
                            Text(goal.unit).font(.title3).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        Spacer(minLength: 12)
                        if !open {
                            GoalChart(lines: lines, compact: true).frame(width: 118, height: 44)
                        }
                    }
                    Text(line(from: from, now: now)).font(.subheadline).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(open ? "Hide the trend" : "Show the trend and change the target")
            if open {
                details(lines, from: from, now: now, forecast: forecast)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24))
        .clipped()
    }

    private func details(_ lines: GoalChart.Lines, from: Double, now: Double, forecast: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GoalChart(lines: lines, compact: false)
                .frame(height: 150)
                .padding(.top, 14)
                .accessibilityLabel("\(option.name) from \(format(from)) to \(format(now)), goal \(format(goal.target)) by \(day(end))")
            HStack(spacing: 14) {
                legend("Logged", StrokeStyle(lineWidth: 2), .primary)
                legend("Plan", StrokeStyle(lineWidth: 2, dash: [3, 3]), Color(.systemGray3))
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
                Nudge(label: "\(format(goal.target)) \(goal.unit)", lessLabel: "Lower the target", moreLabel: "Raise the target",
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

    /// The program's line for the goal: from where it started to the target, flat through deloads and travel.
    private func plan(from: Double) -> [DatedValue] {
        [DatedValue(date: start, value: from)] + weeks.indices.map { index in
            DatedValue(date: min(ProgramPlan.monday(index + 1, start: start), end),
                       value: ProgramPlan.expected(from: from, target: goal.target, at: index, weeks: weeks))
        }
    }

    /// "29 lb up since Aug 10 · 45% there".
    private func line(from: Double, now: Double) -> String {
        let moved = abs(now - from)
        let percent = Int((GoalProgress.fraction(from: from, now: now, target: goal.target) * 100).rounded())
        guard moved > 0 else { return "Started at \(format(from)) on \(day(start))" }
        let direction = (now < from) ? "down" : "up"
        return "\(Coach.number(moved)) \(goal.unit) \(direction) since \(day(start)) · \(percent)% there"
    }

    private func facts(from: Double, now: Double, forecast: Double?) -> [(String, String)] {
        var facts: [(String, String)] = []
        if let forecast { facts.append(("At this rate", "\(format(forecast)) \(goal.unit) by \(day(end))")) }
        let perWeek = GoalProgress.perWeek(now: now, target: goal.target, today: .now, end: end)
        let there = GoalProgress.fraction(from: from, now: now, target: goal.target) >= 1
        facts.append(("To get there", there ? "Already there" : "\(Coach.number(abs(perWeek))) \(goal.unit) a week"))
        if option.measure == .body {
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

    /// Maxes and reps in whole numbers, body weight to a tenth.
    private func format(_ value: Double) -> String {
        Coach.number(option.measure == .body ? value : value.rounded())
    }

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
                default: Capsule().fill(Color(.tertiarySystemFill))
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
    }

    let lines: Lines
    let compact: Bool

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
                    .lineStyle(StrokeStyle(lineWidth: compact ? 2 : 2.5, lineCap: .round, lineJoin: .round))
                if !compact {
                    PointMark(x: .value("Date", point.date), y: .value("Value", point.value)).foregroundStyle(Color.primary).symbolSize(20)
                }
            }
            if compact {
                PointMark(x: .value("Date", last.date), y: .value("Value", last.value)).foregroundStyle(Color.primary).symbolSize(28)
            } else {
                RuleMark(y: .value("Goal", lines.target)).foregroundStyle(Color(.separator)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            PointMark(x: .value("Date", lines.end), y: .value("Value", lines.target))
                .symbol {
                    Circle().fill(Color(.secondarySystemBackground))
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: compact ? 1.5 : 2))
                        .frame(width: compact ? 7 : 9, height: compact ? 7 : 9)
                }
                .annotation(position: lines.target >= lines.plan[0].value ? .bottom : .top, alignment: .trailing, spacing: 6) {
                    if !compact { Text("Goal \(Coach.number(lines.target))").font(.caption2).foregroundStyle(.secondary) }
                }
        }
        .chartXScale(domain: lines.start...lines.end)
        .chartYScale(domain: domain)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis {
            if !compact {
                AxisMarks(values: [lines.start, Date.now, lines.end]) { value in
                    AxisValueLabel(anchor: anchor(value.index, count: value.count)) {
                        Text(label(value.index))
                    }
                }
            }
        }
        .accessibilityHidden(compact)
    }

    private func label(_ index: Int) -> String {
        index == 1 ? "Today" : (index == 0 ? lines.start : lines.end).formatted(.dateTime.month(.abbreviated).day())
    }

    private func anchor(_ index: Int, count: Int) -> UnitPoint {
        index == 0 ? .topLeading : index == count - 1 ? .topTrailing : .top
    }
}
