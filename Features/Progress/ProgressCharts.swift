import Charts
import SwiftUI

/// FIT-337's charts of someone's training, from their sync units: each main lift's estimated max, sessions done of
/// planned, and check-ins. FIT-358: the coach sees them for a client, and the person for themselves on Progress.
struct ProgressCharts<CheckInsTop: View>: View {
    let units: [String: String]
    let sets: [LoggedSet]
    let names: [String: String]
    /// What heads the check-ins: the coach's check-in day picker, or nothing.
    @ViewBuilder var checkInsTop: CheckInsTop

    var body: some View {
        lifts
        weeks
        checkIns
    }

    static func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Self.section(title, content)
    }

    @ViewBuilder private var lifts: some View {
        let lifts = ClientProgress.mainLifts(sets)
        section("Estimated max") {
            if lifts.isEmpty {
                Text("Nothing lifted with a weight yet.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            ForEach(lifts, id: \.self) { slug in
                let trend = Training.estimated1RMTrend(sets, exercise: slug)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(names[slug] ?? slug).font(.headline)
                        Spacer()
                        if let last = trend.last {
                            Text("\(Coach.number(last.value.rounded())) lb").font(.headline).monospacedDigit()
                        }
                    }
                    // A flat line says nothing a number doesn't.
                    if Set(trend.map(\.value)).count > 1 {
                        Chart(trend, id: \.date) { point in
                            LineMark(x: .value("Day", point.date), y: .value("lb", point.value))
                                .foregroundStyle(Plate.current.mark).interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartXAxis(.hidden)
                        .frame(height: 64)
                    }
                }
            }
        }
    }

    private var weeks: some View {
        let weeks = ClientProgress.weeks(units, today: .now)
        return section("Sessions, last 8 weeks") {
            Chart(weeks, id: \.sunday) { week in
                // Done, then what's left of the planned on top, so the bar is as tall as the week's plan.
                BarMark(x: .value("Week", week.sunday, unit: .weekOfYear), y: .value("Sessions", week.done))
                    .foregroundStyle(Plate.current.mark)
                BarMark(x: .value("Week", week.sunday, unit: .weekOfYear), y: .value("Sessions", max(0, week.planned - week.done)))
                    .foregroundStyle(Color.fill)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            // FIT-367: four dates across a phone's width overlap past this size; the chart is read by its bars.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(height: 120)
            let done = weeks.map(\.done).reduce(0, +), planned = weeks.map(\.planned).reduce(0, +)
            Text(planned == 0 ? "Nothing planned yet" : "\(done) of \(planned) sessions done")
                .font(.subheadline).foregroundStyle(Color.inkMuted)
        }
    }

    @ViewBuilder private var checkIns: some View {
        let weighIns = ClientProgress.checkIns(units, "weight_lb")
        let sleep = ClientProgress.checkIns(units, "sleep_h").filter { $0.date > Date.now.addingTimeInterval(-7 * 86_400) }
        let notes = ClientProgress.notes(units).prefix(3)
        let weekly = ClientProgress.weekly(units).first
        section("Check-ins") {
            checkInsTop
            if let weekly {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Weekly check-in").font(.headline)
                        Spacer()
                        Text(weekly.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                    Text(WeeklyCheckIn.summary(weekly.values)).font(.subheadline).monospacedDigit()
                    let worries = WeeklyCheckIn.concerns(weekly.values)
                    if !worries.isEmpty { Text(worries.joined(separator: ", ").capitalized(with: nil)).font(.footnote.weight(.semibold)).foregroundStyle(Color.warn) }
                    if !weekly.note.isEmpty { Text(weekly.note).font(.subheadline) }
                }
            }
            if weighIns.isEmpty && sleep.isEmpty && notes.isEmpty && weekly == nil {
                Text("No check-ins yet.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            if let last = weighIns.last {
                HStack { Text("Weight"); Spacer(); Text("\(Coach.number(last.value)) lb").monospacedDigit().bold() }
                if weighIns.count > 1 {
                    Chart(weighIns, id: \.date) { LineMark(x: .value("Day", $0.date), y: .value("lb", $0.value)).foregroundStyle(Plate.current.mark) }
                        .chartYScale(domain: .automatic(includesZero: false)).chartXAxis(.hidden).frame(height: 56)
                }
            }
            if !sleep.isEmpty {
                let average = sleep.map(\.value).reduce(0, +) / Double(sleep.count)
                HStack { Text("Sleep, last 7 days"); Spacer(); Text("\(Coach.number((average * 10).rounded() / 10)) h a night").monospacedDigit().bold() }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(note.text)”")
                    Text(note.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
        }
    }
}

extension ProgressCharts where CheckInsTop == EmptyView {
    init(units: [String: String], sets: [LoggedSet], names: [String: String]) {
        self.init(units: units, sets: sets, names: names) { EmptyView() }
    }
}
