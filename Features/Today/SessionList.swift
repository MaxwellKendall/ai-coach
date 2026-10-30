import SwiftUI

/// FIT-297, design A: today's session as a list. The warm-up first, folded to one line; each lift with its sets and its
/// load, big, and "+5 lb" when it went up; a superset's lifts bracketed with A and B. Tap a lift to check it off as
/// done (L3), tap its load to change it right there (E1). Prototype: https://claude.ai/artifact/QBzBgYEd35faydgEk8Qo3f
struct SessionList: View {
    let session: SessionPlan
    let names: [String: String]
    /// The last working load logged for each exercise, for "+5 lb".
    let previous: [String: Double]
    /// Blocks checked off as done, by index (a session's blocks are rebuilt on every change); nil when it can't be
    /// checked off (not today).
    var checked: Binding<Set<Int>>?
    /// A load changed in place: the exercise and the step (±5 lb).
    var onLoad: ((String, Double) -> Void)?
    @State private var warm = false
    /// The exercise whose load is being changed.
    @State private var editing: String?

    var body: some View {
        VStack(spacing: 0) {
            if !session.warmup.isEmpty || firstLoad != nil { warmup(firstLoad) }
            // FIT-300: the written warm-up's blocks are in the warm-up row, not among the lifts; indices stay the session's.
            ForEach(session.blocks.indices.filter { session.blocks[$0].rounds > 0 }, id: \.self) { index in
                let block = session.blocks[index]
                if block.isGroup { superset(block, index: index) } else if let movement = block.movements.first { row(movement, block: index) }
            }
        }
        .animation(.snappy, value: warm)
        .animation(.snappy, value: editing)
    }

    /// The first lift's working weight, the warm-up's target; none for a session without a loaded lift first.
    private var firstLoad: (name: String, load: Double)? {
        guard let movement = session.blocks.first(where: { $0.rounds > 0 })?.movements.first, let load = Self.load(movement),
              load > WarmupRamp.bar else { return nil }
        return (names[movement.exercise] ?? movement.exercise, load)
    }

    /// "Rowing Machine, Band Pull-Apart, then ramp to 170", the coach's warm-up (FIT-300), or the computed one:
    /// "9 min · easy cardio, then ramp to 170".
    private func warmupLine(_ first: (name: String, load: Double)?) -> String {
        let ramp = first.map { "ramp to \(Coach.number($0.load))" }
        guard !session.warmup.isEmpty else { return "\(WarmupRamp.minutes(to: first?.load ?? 0)) min · easy cardio, then \(ramp ?? "")" }
        return ([session.warmup.map { names[$0.exercise] ?? $0.exercise }.joined(separator: ", ")] + [ramp.map { "then \($0)" }].compactMap { $0 })
            .joined(separator: ", ")
    }

    /// A written warm-up item's dose: "5 min", "2 × 15", "2 × 30 s", "1 × 10 @ 45".
    private static func warmupDose(_ movement: SessionPlan.Movement) -> String {
        let count = movement.sets.count, set = movement.sets.first
        if let seconds = set?.value("duration_s") {
            let time = seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
            return count > 1 ? "\(count) × \(time)" : time
        }
        guard let reps = set?.value("reps") else { return "\(count) \(count == 1 ? "set" : "sets")" }
        return "\(count) × \(Coach.number(reps))" + ((set?.value("load_lb")).map { " @ \(Coach.number($0))" } ?? "")
    }

    private func warmup(_ first: (name: String, load: Double)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { warm.toggle() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WARM-UP").font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(Color.inkMuted)
                        Text(warmupLine(first)).font(.body.weight(.semibold))
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).frame(width: 28, height: 28)
                        .background(Color.fill, in: .circle).rotationEffect(.degrees(warm ? 180 : 0))
                }
                .padding(.vertical, 12).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(warm ? "Hides the warm-up" : "Shows the warm-up")
            if warm {
                VStack(alignment: .leading, spacing: 10) {
                    if session.warmup.isEmpty {
                        HStack { Text("Row, bike or walk, easy").foregroundStyle(Color.inkMuted); Spacer(); Text("\(WarmupRamp.cardioMinutes) min").bold() }
                    } else {
                        ForEach(session.warmup) { movement in
                            HStack { Text(names[movement.exercise] ?? movement.exercise).foregroundStyle(Color.inkMuted); Spacer(); Text(Self.warmupDose(movement)).bold() }
                        }
                    }
                    if let first {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(first.name) ramp").foregroundStyle(Color.inkMuted)
                            HStack(spacing: 6) {
                                ForEach(WarmupRamp.steps(to: first.load), id: \.load) { step in
                                    Text("\(step.load == WarmupRamp.bar ? "Bar" : Coach.number(step.load)) × \(step.reps)")
                                        .font(.display(15, weight: .semibold, relativeTo: .subheadline)).monospacedDigit()
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Color.fill, in: .rect(cornerRadius: 8))
                                        .lineLimit(1).fixedSize()
                                }
                            }
                        }
                    }
                }
                .font(.subheadline)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func superset(_ block: SessionPlan.Block, index blockIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("SUPERSET").font(.caption.weight(.bold)).tracking(0.6) + Text(" · alternate, rest after both").font(.caption))
                .foregroundStyle(Color.inkMuted).padding(.top, 12)
            ForEach(Array(block.movements.enumerated()), id: \.element.id) { index, movement in
                row(movement, block: blockIndex, letter: String(UnicodeScalar(UInt8(65 + index))), last: index == block.movements.count - 1)
            }
            .padding(.leading, 20)
            .background(alignment: .leading) {
                // The bracket: lifts done back to back, as coaches write A1/A2.
                Bracket().stroke(Color.inkFaint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 10).padding(.vertical, 24).padding(.leading, 4)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ movement: SessionPlan.Movement, block: Int, letter: String? = nil, last: Bool = true) -> some View {
        let done = checked?.wrappedValue.contains(block) == true
        let load = Self.load(movement)
        let up = load.flatMap { load in previous[movement.exercise].map { load - $0 } }.flatMap { $0 > 0 ? $0 : nil }
        return HStack(alignment: .center, spacing: 12) {
            if let checked {
                Button { toggle(block, in: checked) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title2)
                        .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.inkFaint))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Done" : "Check off as done")
            }
            if let letter {
                Text(letter).font(.caption2.weight(.heavy)).foregroundStyle(Color.inkMuted)
                    .frame(width: 18, height: 18).background(Color.surface, in: .circle)
                    .overlay { Circle().stroke(Color.inkFaint, lineWidth: 2) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(names[movement.exercise] ?? movement.exercise).font(.body.weight(.semibold))
                        .foregroundStyle(done ? Color.inkMuted : Color.ink)
                    if let up {
                        Text("+\(Coach.number(up)) lb").font(.caption.weight(.bold)).foregroundStyle(.tint)
                            .padding(.horizontal, 7).padding(.vertical, 1).background(.tint.opacity(0.12), in: .capsule)
                    }
                }
                Text(Self.dose(movement)).font(.footnote).foregroundStyle(Color.inkMuted)
            }
            .contentShape(.rect)
            .onTapGesture { if let checked { toggle(block, in: checked) } }
            Spacer(minLength: 8)
            loadView(movement, load: load)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if letter == nil || !last { Divider() } }
    }

    @ViewBuilder private func loadView(_ movement: SessionPlan.Movement, load: Double?) -> some View {
        if let load, let onLoad, editing == movement.exercise {
            HStack(spacing: 6) {
                stepButton("minus", "5 lb less") { onLoad(movement.exercise, -5) }
                Text(Coach.number(load)).font(.display(22, weight: .semibold, relativeTo: .title2)).monospacedDigit().frame(minWidth: 48)
                stepButton("plus", "5 lb more") { onLoad(movement.exercise, 5) }
            }
            .transition(.opacity)
        } else if let load {
            Button { editing = editing == movement.exercise ? nil : movement.exercise } label: {
                (Text(Coach.number(load)).font(.display(22, weight: .semibold, relativeTo: .title2))
                 + Text(" lb").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .disabled(onLoad == nil)
            .accessibilityHint(onLoad == nil ? "" : "Change the weight")
        } else {
            Text("Body weight").font(.subheadline).foregroundStyle(Color.inkMuted)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).frame(width: 34, height: 34).background(Color.fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggle(_ block: Int, in checked: Binding<Set<Int>>) {
        if checked.wrappedValue.contains(block) { checked.wrappedValue.remove(block) } else { checked.wrappedValue.insert(block) }
    }

    static func load(_ movement: SessionPlan.Movement) -> Double? {
        movement.working.first.flatMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }
    }

    /// "3 sets of 5", "3 sets of 8–12", "3 sets of 40 s".
    static func dose(_ movement: SessionPlan.Movement) -> String {
        let working = movement.working
        guard let first = working.first else { return "" }
        let amount = Coach.amount(reps: first.value("reps"), meters: first.value("distance_m"), seconds: first.value("duration_s")) ?? ""
        return working.count == 1 ? "1 set of \(amount)" : "\(working.count) sets of \(amount)"
    }
}

/// A superset's bracket: open on the right, rounded at both ends.
private struct Bracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(8, rect.width)
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
