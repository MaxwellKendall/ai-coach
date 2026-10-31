import SwiftUI

/// FIT-302: Move on Today: today's session to another day this week, the rest of the week shifting so nothing doubles
/// up (the proposal shows how before it's applied). The other quick fixes Change offered are gone: the session is edited
/// by hand on Today.
struct MoveSheet: View {
    var onMove: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Move to another day").font(.display(24, relativeTo: .title))
                Text("The rest of the week shifts so nothing doubles up.")
                    .font(.subheadline).foregroundStyle(Color.inkMuted).padding(.top, 4).padding(.bottom, 14)
                if Self.days.isEmpty {
                    Text("This is the week's last day.").foregroundStyle(Color.inkMuted)
                }
                ForEach(Self.days, id: \.index) { day in
                    Button { onMove(day.index) } label: {
                        Text(day.name).font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(Color.fill, in: .rect(cornerRadius: 14))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
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
}
