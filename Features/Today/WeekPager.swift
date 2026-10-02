import SwiftUI

/// Mon–Sun strip plus one swipeable page per day, opening on today.
struct WeekPager: View {
    let days: [Date]
    let items: [PlannedActivity]
    let names: [UUID: String]
    @State private var day: Int?

    init(days: [Date], items: [PlannedActivity], names: [UUID: String], today: Date = .now) {
        self.days = days
        self.items = items
        self.names = names
        let calendar = Calendar.current
        _day = State(initialValue: days.firstIndex { calendar.isDate($0, inSameDayAs: today) } ?? 0)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    let selected = index == day
                    Button {
                        withAnimation(.snappy) { day = index }
                    } label: {
                        VStack(spacing: 2) {
                            Text(days[index].formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                .font(.caption2.weight(.semibold))
                            Text(days[index].formatted(.dateTime.day()))
                                .font(.system(size: 20, weight: .bold)).fontWidth(.condensed)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? Color.primary : .clear, in: .rect(cornerRadius: 12))
                        .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                        .overlay(alignment: .bottom) {
                            if !selected, items.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: days[index]) }) {
                                Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: 4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(days.indices, id: \.self) { index in
                        DayPage(items: items.filter { Calendar.current.isDate($0.date, inSameDayAs: days[index]) },
                                names: names)
                            .padding(.horizontal, 16)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $day)
        }
    }
}

struct DayPage: View {
    let items: [PlannedActivity]
    let names: [UUID: String]

    var body: some View {
        let workout = items.filter { $0.kind == .workout }.sorted { $0.date < $1.date }
        VStack(spacing: 8) {
            if items.isEmpty {
                Text("Nothing planned")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .foregroundStyle(.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(dash: [5, 4])))
            }
            if !workout.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(["WORKOUT", workout.first?.slot?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold)).opacity(0.7)
                    ForEach(workout) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.templateRef.flatMap { names[$0] } ?? "Exercise").fontWeight(.semibold)
                            Spacer()
                            Text(Self.targets(item.targets)).opacity(0.7)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary, in: .rect(cornerRadius: 20))
                .foregroundStyle(Color(.systemBackground))
            }
            ForEach(items.filter { $0.kind != .workout }.sorted { $0.date < $1.date }) { item in
                HStack {
                    Text(item.templateRef.flatMap { names[$0] } ?? item.kind.rawValue.capitalized)
                        .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                    Spacer()
                    if let slot = item.slot { Text(slot).foregroundStyle(.secondary) }
                }
                .padding(14)
                .background(.background, in: .rect(cornerRadius: 16))
            }
        }
        .font(.subheadline)
    }

    /// "3×5 @ 155 lb", falling back to each measurement's own display.
    nonisolated static func targets(_ targets: [Measurement]) -> String {
        func value(_ metric: String) -> Double? { targets.first { $0.metric == metric }?.value }
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
        var parts: [String] = []
        var rest = targets
        if let sets = value("sets"), let reps = value("reps") {
            parts.append("\(number(sets))×\(number(reps))")
            rest.removeAll { ["sets", "reps"].contains($0.metric) }
        }
        if let load = value("load_lb") {
            parts.append("@ \(number(load)) lb")
            rest.removeAll { $0.metric == "load_lb" }
        }
        return (parts + rest.map(\.display)).joined(separator: " ")
    }
}
