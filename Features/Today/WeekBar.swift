import SwiftUI

/// FIT-331, FIT-332: the week shown, ‹ ›, and "This Week" to come back, as Calendar's week view has them. One control
/// for any screen that pages weeks (a client's, Today), so they behave the same. `go` gets the new week's Sunday.
struct WeekBar: View {
    /// The Sunday of the week shown.
    let start: Date
    let go: (Date) -> Void

    private var thisWeek: Bool { start == Week.start(of: .now) }

    var body: some View {
        HStack(spacing: 4) {
            Text(thisWeek ? "This week" : Self.range(start)).font(.headline).contentTransition(.numericText())
            Spacer()
            if !thisWeek {
                Button("This Week") { go(Week.start(of: .now)) }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Plate.current.mark)
                    .padding(.trailing, 6)
            }
            ForEach([-1, 1], id: \.self) { step in
                Button { go(Self.week(step, from: start)) } label: {
                    Image(systemName: step < 0 ? "chevron.left" : "chevron.right").font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36).background(Color.fill, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step < 0 ? "Previous week" : "Next week")
            }
        }
    }

    static func week(_ weeks: Int, from start: Date) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: start)!
    }

    /// "Nov 2 – 8", or "Oct 26 – Nov 1" across a month.
    static func range(_ start: Date) -> String {
        let last = Calendar.current.date(byAdding: .day, value: 6, to: start)!
        let sameMonth = Calendar.current.isDate(start, equalTo: last, toGranularity: .month)
        let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
    }

    /// Swipe a week strip to the next or previous week. Alongside the strip's own taps on its days.
    static func swipe(_ go: @escaping (Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 24).onEnded { drag in
            guard abs(drag.translation.width) > abs(drag.translation.height), abs(drag.translation.width) > 40 else { return }
            go(drag.translation.width < 0 ? 1 : -1)
        }
    }
}
