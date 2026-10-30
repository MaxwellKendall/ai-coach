import SwiftUI

/// FIT-297: Change on Today. The quick fixes the plan's rules already make (shorter, around something that hurts,
/// easier, another day), each opening the proposal to apply, then the exercises themselves. Replaces the ••• menu.
struct ChangeSheet: View {
    enum Choice { case change(SpokenRequest.Change), exercises, week }

    var canChangeWeek: Bool
    var onChoose: (Choice) -> Void
    @State private var step: Step?

    private enum Step { case hurts, move }
    private static let areas = ["Shoulder", "Elbow", "Wrist", "Lower back", "Hip", "Knee"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step == .hurts ? "Where does it hurt?" : step == .move ? "Which day?" : "Change today")
                .font(.display(30, weight: .heavy, relativeTo: .title)).textCase(.uppercase)
            Text(step == nil ? "Today’s workout adapts. Your goal date stays honest: you’ll see if it moves." : "The lifts that load it are swapped or dropped.")
                .font(.subheadline).foregroundStyle(Color.inkMuted).padding(.top, 4).padding(.bottom, 14)
                .opacity(step == .move ? 0 : 1)
            switch step {
            case nil:
                option("Short on time", "Cut to 30 minutes; the main lifts stay.") { onChoose(.change(.time(minutes: 30))) }
                option("Something hurts", "Tell it where; the lifts that load it change.") { withAnimation(.snappy) { step = .hurts } }
                option("Low on energy", "Fewer sets and an easier effort cap.") { onChoose(.change(.energy)) }
                option("Move to another day", "The rest of the week shifts so nothing doubles up.") { withAnimation(.snappy) { step = .move } }
                option("Swap or remove an exercise", "Same muscles, a different lift, or one fewer.") { onChoose(.exercises) }
                if canChangeWeek { option("Change this week", "Days, length and what to avoid.") { onChoose(.week) } }
            case .hurts?:
                ForEach(Self.areas, id: \.self) { area in option(area, nil) { onChoose(.change(.injury(area: area))) } }
            case .move?:
                ForEach(Self.days, id: \.index) { day in option(day.name, nil) { onChoose(.change(.move(weekday: day.index))) } }
            }
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The days left this week after today, as offsets from Monday.
    private static var days: [(index: Int, name: String)] {
        let start = Week.start(of: .now), calendar = Calendar.current
        return (0..<7).compactMap { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return calendar.startOfDay(for: day) > calendar.startOfDay(for: .now) ? (offset, day.formatted(.dateTime.weekday(.wide))) : nil
        }
    }

    private func option(_ title: String, _ detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if let detail { Text(detail).font(.footnote).foregroundStyle(Color.inkMuted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.fill, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

/// FIT-297: Log on Today, for training done without pressing Start: today's session (every set filled in as
/// planned, to fix), a different workout, or a run, class or sport.
struct LogChoiceSheet: View {
    enum Choice { case today, other, run }

    var hasToday: Bool
    var onChoose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log a workout").font(.display(30, weight: .heavy, relativeTo: .title)).textCase(.uppercase)
            Text("Did it without the app, or did something different? Log it so the plan keeps up.")
                .font(.subheadline).foregroundStyle(Color.inkMuted).padding(.bottom, 6)
            if hasToday { option("I did today’s workout", "Every set is filled in as planned; fix any that were different.") { onChoose(.today) } }
            option("I did a different workout", "Pick the exercises, then log the sets.") { onChoose(.other) }
            option("A run, class or sport", "Distance, time and how it felt.") { onChoose(.run) }
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.fill, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
