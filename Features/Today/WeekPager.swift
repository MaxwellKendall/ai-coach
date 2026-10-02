import SwiftUI

/// Mon–Sun strip plus one swipeable page per day, opening on today.
struct WeekPager: View {
    let days: [Date]
    let items: [PlannedActivity]
    let names: [UUID: String]
    let logged: Set<UUID>
    let onLog: ([PlannedActivity]) -> Void
    let onEdit: ([PlannedActivity]) -> Void
    @State private var day: Int?

    init(days: [Date], items: [PlannedActivity], names: [UUID: String], logged: Set<UUID>,
         today: Date = .now, onLog: @escaping ([PlannedActivity]) -> Void, onEdit: @escaping ([PlannedActivity]) -> Void) {
        self.days = days
        self.items = items
        self.names = names
        self.logged = logged
        self.onLog = onLog
        self.onEdit = onEdit
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
                                names: names, logged: logged,
                                isToday: Calendar.current.isDateInToday(days[index]), onLog: onLog, onEdit: onEdit)
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
    var logged: Set<UUID> = []
    var isToday = false
    var onLog: ([PlannedActivity]) -> Void = { _ in }
    var onEdit: ([PlannedActivity]) -> Void = { _ in }

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
                    HStack {
                        Text(workout.first?.slot?.uppercased() ?? "WORKOUT")
                        Spacer()
                        if let start = workout.first?.date { Text(start.formatted(date: .omitted, time: .shortened)) }
                        if !isLogged(workout) {
                            Button("Edit workout", systemImage: "pencil") { onEdit(workout) }
                                .labelStyle(.iconOnly)
                                .font(.subheadline.weight(.bold))
                                .frame(width: 36, height: 28)
                                .background(Color(.systemBackground).opacity(0.15), in: .capsule)
                                .contentShape(.rect.inset(by: -8))
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
                    ForEach(workout) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.templateRef.flatMap { names[$0] } ?? "Exercise")
                                    .fontWeight(item.note == TrainingGenerator.warmupNote ? .regular : .semibold)
                                if !item.note.isEmpty || item.adjustedReason != nil {
                                    Text([item.note, item.adjustedReason ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).opacity(0.6)
                                }
                            }
                            Spacer()
                            Text(Self.targets(item.targets)).opacity(0.7)
                        }
                    }
                    if isLogged(workout) {
                        Label("Logged", systemImage: "checkmark.circle.fill").fontWeight(.semibold).foregroundStyle(.tint)
                    } else {
                        Button { onLog(workout) } label: {
                            // Today's session runs live in workout mode; other days are logged after the fact.
                            Text(isToday ? "Start workout" : "Log workout").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .background(.tint, in: .rect(cornerRadius: 12))
                        .foregroundStyle(Color(.label))
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary, in: .rect(cornerRadius: 20))
                .foregroundStyle(Color(.systemBackground))
            }
            ForEach(items.filter { $0.kind != .workout }.sorted { $0.date < $1.date }) { item in
                Button { onLog([item]) } label: {
                HStack {
                    if logged.contains(item.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    Text(item.templateRef.flatMap { names[$0] } ?? item.slot ?? item.kind.rawValue.capitalized)
                        .fontWeight(.semibold).foregroundStyle(.tint)
                    Spacer()
                    Text(([item.date.formatted(date: .omitted, time: .shortened)] + item.targets.map(\.display))
                        .joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.background, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(logged.contains(item.id))
            }
        }
        .font(.subheadline)
    }

    private func isLogged(_ workout: [PlannedActivity]) -> Bool { workout.contains { logged.contains($0.id) } }

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
        if let rpe = value("rpe") {
            rest.removeAll { $0.metric == "rpe" }
            return (parts + rest.map(\.display) + ["RPE \(number(rpe))"]).joined(separator: " ")
        }
        return (parts + rest.map(\.display)).joined(separator: " ")
    }
}
