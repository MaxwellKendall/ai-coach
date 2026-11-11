import SwiftUI
import SwiftData

/// The warm-up items of a session, each with its dose, − and + (a minute, or a rep) and ✕.
struct WarmupList: View {
    @Binding var session: SessionPlan
    let names: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.blocks.indices.filter { session.blocks[$0].rounds == 0 }, id: \.self) { index in
                ForEach(session.blocks[index].movements.indices, id: \.self) { m in
                    row(block: index, movement: m)
                }
            }
        }
    }

    private func row(block index: Int, movement m: Int) -> some View {
        let movement = session.blocks[index].movements[m]
        let name = names[movement.exercise] ?? movement.exercise
        let timed = movement.sets.first?.value("duration_s") != nil
        let metric = timed ? "duration_s" : "reps"
        let step: Double = timed ? 60 : 1
        let value = movement.sets.first?.value(metric) ?? (timed ? 300 : 10)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold)).lineLimit(2)
                Text(movement.warmupDose).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
            }
            Spacer(minLength: 8)
            button("minus", timed ? "A minute less" : "One fewer") {
                session.set(metric, to: max(step, value - step), block: index, movement: m, set: 0, remaining: true)
            }
            button("plus", timed ? "A minute more" : "One more") {
                session.set(metric, to: value + step, block: index, movement: m, set: 0, remaining: true)
            }
            button("xmark", "Remove \(name)") { withAnimation(.settle) { session.remove(block: index, movement: m) } }
        }
        .padding(.vertical, 8)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote.weight(.bold)).frame(width: 36, height: 36).background(Color.fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
