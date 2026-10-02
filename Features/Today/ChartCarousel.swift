import SwiftUI
import Charts

/// One full-width page of the Today carousel. Every number is derived from log entries.
enum ChartPage {
    case lift(name: String, trend: [DatedValue], goal: Double?)
    case daily(name: String, unit: String, values: [DatedValue], goal: Double?)
    case volume(setsByPattern: [String: Int], endingOn: Date)
}

struct ChartCarousel: View {
    let pages: [ChartPage]
    @State private var page: Int? = 0

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        ChartPageView(page: pages[index])
                            .padding(16)
                            .frame(height: 250)
                            .background(.background, in: .rect(cornerRadius: 20))
                            .padding(.horizontal, 16)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)

            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == (page ?? 0) ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: index == (page ?? 0) ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: page)
            }
        }
    }
}

private struct ChartPageView: View {
    let page: ChartPage

    var body: some View {
        switch page {
        case let .lift(name, trend, goal): lift(name, trend, goal)
        case let .daily(name, unit, values, goal): daily(name, unit, values, goal)
        case let .volume(sets, end): volume(sets, end)
        }
    }

    private func lift(_ name: String, _ trend: [DatedValue], _ goal: Double?) -> some View {
        let first = trend.first!, latest = trend.last!
        return VStack(alignment: .leading, spacing: 6) {
            header(name, value: latest.value, unit: "lb e1RM") {
                if latest.value > first.value {
                    Text("+\(whole(latest.value - first.value)) since \(first.date.formatted(.dateTime.month().day()))")
                        .foregroundStyle(.green)
                }
                if let goal, goal > latest.value {
                    Text("\(whole(goal - latest.value)) lb to \(whole(goal))").foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(trend, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                        .symbolSize(20)
                        .foregroundStyle(Color.accentColor)
                }
                if let goal { target(goal) }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private func daily(_ name: String, _ unit: String, _ values: [DatedValue], _ goal: Double?) -> some View {
        let average = values.map(\.value).reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: 6) {
            header(name, value: average, unit: "\(unit) avg") {
                if let goal {
                    Text("\(values.filter { $0.value >= goal }.count) of \(values.count) days hit \(whole(goal))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("last \(values.count) logged days").foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(values, id: \.date) { point in
                    BarMark(x: .value("Day", point.date.formatted(.dateTime.month(.defaultDigits).day())),
                            y: .value(name, point.value))
                        .foregroundStyle(goal.map { point.value >= $0 } ?? true ? Color.accentColor : .secondary.opacity(0.4))
                }
                if let goal { target(goal) }
            }
        }
    }

    private func volume(_ sets: [String: Int], _ end: Date) -> some View {
        let rows = sets.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            header("Sets per pattern", value: Double(sets.values.reduce(0, +)), unit: "sets") {
                Text("28 days to \(end.formatted(.dateTime.month().day()))").foregroundStyle(.secondary)
            }
            Chart(rows, id: \.key) { row in
                BarMark(x: .value("Sets", row.value), y: .value("Pattern", row.key.capitalized), height: .ratio(0.6))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(.rect(cornerRadius: 4))
                    .annotation(position: .trailing) { Text("\(row.value)").font(.caption).foregroundStyle(.secondary) }
            }
            .chartXAxis(.hidden)
        }
    }

    private func header(_ name: String, value: Double, unit: String,
                        @ViewBuilder detail: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(whole(value)).font(.system(size: 40, weight: .bold)).fontWidth(.condensed)
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10, content: detail).font(.caption.weight(.medium))
        }
    }

    private func target(_ goal: Double) -> some ChartContent {
        RuleMark(y: .value("Goal", goal))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.secondary)
    }

    private func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
