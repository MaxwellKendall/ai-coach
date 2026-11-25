import SwiftUI

/// FIT-325 + TKL-934 (C3): a ready-made program past its last week: its recap counts up,
/// the phase bars fill one last time, crescendo plays, and the next program's card slides in.
struct ProgramDoneCard: View {
    let finished: ReadyProgram
    let next: ReadyProgram
    var weeks: [ProgramWeek] = []
    var sessionsDone: Int = 0
    var personalBests: Int = 0
    var reduceMotion = false
    var recap: () -> Void
    var start: () -> Void
    var pick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var played = false
    @State private var shownWeeks = 0.0
    @State private var shownSessions = 0.0
    @State private var shownBests = 0.0
    @State private var barsFilled = false
    @State private var nextVisible = false
    @State private var haptics = HapticPlayer()

    private var reduced: Bool { reduceMotion || systemReduceMotion }

    private var barData: [(height: CGFloat, deload: Bool)] {
        if !weeks.isEmpty {
            return weeks.map { week in
                let h: CGFloat = switch week.kind {
                case .deload: 0.32
                case .test: 1.0
                default: week.phase == .base ? 0.55 : week.phase == .build ? 0.78 : 0.92
                }
                return (h, week.kind == .deload)
            }
        }
        let count = max(1, finished.weeks)
        return (0..<count).map { i in
            let deload = (i + 1) % 4 == 0
            let h: CGFloat = deload ? 0.34 : min(0.95, 0.45 + 0.50 * CGFloat(i) / CGFloat(max(1, count - 1)))
            return (h, deload)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Program done")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.inkMuted)
            Text("You finished \(finished.name)")
                .font(.title3.weight(.bold))
                .padding(.top, 2)

            HStack(spacing: 8) {
                recapStat(shownWeeks, label: finished.weeks == 1 ? "week" : "weeks")
                recapStat(shownSessions, label: sessionsDone == 1 ? "session" : "sessions")
                recapStat(shownBests, label: personalBests == 1 ? "personal best" : "personal bests")
            }
            .padding(.top, 14)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(barData.enumerated()), id: \.offset) { index, bar in
                    RoundedRectangle(cornerRadius: 3) // ui-score: allow radius-scale: a bar in a small bar chart
                        .fill(Color.ink.opacity(bar.deload ? 0.35 : 1))
                        .frame(height: 52 * bar.height)
                        .scaleEffect(y: barsFilled || reduced ? 1 : 0.01, anchor: .bottom)
                        .animation(reduced ? nil : .settle.delay(0.28 + Double(index) * 0.025), value: barsFilled)
                }
            }
            .frame(height: 56, alignment: .bottom)
            .padding(.top, 12)
            .accessibilityHidden(true)

            Button(action: recap) {
                Text("See the recap")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Color.ink)
                    .background(Color.fill, in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("Up next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
                Text("\(next.name) · \(next.weeks) weeks")
                    .font(.headline)
                    .padding(.top, 2)
                Button(action: start) {
                    Text(next.slug == finished.slug ? "Go Again" : "Start \(next.name)")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.primary)
                .padding(.top, 12)
                Button("Pick Another", action: pick)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, 4)
            }
            .padding(16)
            .background(Color.fill, in: .rect(cornerRadius: 18))
            .padding(.top, 14)
            .offset(x: nextVisible || reduced ? 0 : 60)
            .opacity(nextVisible ? 1 : 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .hapticFallback(for: haptics)
        .onAppear { playEntrance() }
    }

    private func recapStat(_ value: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CountingNumber(value: value)
                .font(.display(26, weight: .semibold, design: .rounded, relativeTo: .title2))
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playEntrance() {
        guard !played else { return }
        played = true
        if reduced {
            shownWeeks = Double(finished.weeks)
            shownSessions = Double(sessionsDone)
            shownBests = Double(personalBests)
            barsFilled = true
            withAnimation(.out) { nextVisible = true }
            haptics.play(.crescendo)
            return
        }
        withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.75).delay(0.18)) {
            shownWeeks = Double(finished.weeks)
        }
        withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.75).delay(0.27)) {
            shownSessions = Double(sessionsDone)
        }
        withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.75).delay(0.36)) {
            shownBests = Double(personalBests)
        }
        barsFilled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            haptics.play(.crescendo)
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.settle) { nextVisible = true }
        }
    }
}
