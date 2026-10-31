import SwiftUI

/// FIT-297: Log on Today, for training done without pressing Start: today's session (every set filled in as
/// planned, to fix), a different workout, or a run, class or sport.
struct LogChoiceSheet: View {
    enum Choice { case today, other, run }

    var hasToday: Bool
    var onChoose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log a workout").font(.display(24, relativeTo: .title))
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
