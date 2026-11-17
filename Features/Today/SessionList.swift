import SwiftData
import SwiftUI

/// FIT-297, design A: today's session as a list. The warm-up first, folded to one line; each lift with its sets and its
/// load, big, and "+5 lb" when it went up; a superset's lifts bracketed with A and B. Tap the circle to check a lift off
/// (L3). TKL-753: one session editor. Tapping a lift opens it in place into Program's block card (`BlockEditor`): every set
/// a row, a number tapped for the bottom stepper, Swap / + Set / ⋯ under it; tapping it again folds it. The warm-up opens
/// to its items; Add exercise at the end. Each change is saved as it's made (the screen offers Undo).
/// Prototype: https://claude.ai/artifact/4RAUoAwczRiRNG9NuAu5Vz
struct SessionList: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: SessionPlan
    let names: [String: String]
    /// The last working load logged for each exercise, for "+5 lb".
    let previous: [String: Double]
    /// Blocks checked off as done, by index (a session's blocks are rebuilt on every change); nil when it can't be
    /// checked off (not today).
    var checked: Binding<Set<Int>>?
    /// FIT-302: the session as changed by hand, to save; nil where it can't be changed (another day).
    var onEdit: ((SessionPlan) -> Void)?
    /// FIT-356: the how-to also shows your last sessions of the lift: on your own Today, not a client's day.
    var history = false
    @State private var warm = false
    /// The lift open in place, by block index.
    @State private var open: Int?
    /// The number being changed in the bottom stepper.
    @State private var selected: BlockEditor.Cell?
    @State private var picking: Picking?
    /// FIT-356: the lift whose how-to (and history) is open.
    @State private var looking: String?
    @Query private var templates: [Template]

    /// What the exercise picker is for.
    enum Picking: Identifiable {
        case warmup, add, swap(block: Int, movement: Int, exercise: String)
        var id: String {
            switch self {
            case .warmup: "warm-up"
            case .add: "add"
            case .swap(let block, let movement, _): "swap \(block) \(movement)"
            }
        }
    }

    /// One grid for every row (author: "geometrically perfect"): the check circle and the ＋ share one column, and
    /// every row's text starts on one edge.
    static let column: CGFloat = 28, gap: CGFloat = 12, rowPadding: CGFloat = 16
    /// Where the text starts: past the column on Today, where there's a check circle; flush otherwise.
    private var inset: CGFloat { checked != nil ? Self.column + Self.gap : 0 }

    /// One change to the session, saved.
    private func change(_ edit: (inout SessionPlan) -> Void) {
        var edited = session
        edit(&edited)
        save(edited)
    }

    private func save(_ edited: SessionPlan) {
        // A lift joined, removed or moved: the open one may be gone, so nothing stays open on a stale index.
        if edited.blocks.count != session.blocks.count { open = nil; selected = nil }
        onEdit?(edited)
    }

    /// The editor's way in: every change it makes is saved at once.
    private var editable: Binding<SessionPlan> { Binding(get: { session }, set: { save($0) }) }

    var body: some View {
        VStack(spacing: 0) {
            if !session.warmup.isEmpty || firstLoad != nil {
                warmup(firstLoad)
            } else if onEdit != nil {
                // A session with nothing to warm up to (bodyweight, say) has no warm-up row: offer one.
                addButton("Warm-up") { picking = .warmup }.overlay(alignment: .bottom) { Divider() }
            }
            // FIT-300: the written warm-up's blocks are in the warm-up row, not among the lifts; indices stay the session's.
            let lifts = session.blocks.indices.filter { session.blocks[$0].rounds > 0 }
            ForEach(lifts, id: \.self) { index in
                let block = session.blocks[index]
                // The last lift has no rule under it unless Add exercise follows.
                let ruled = onEdit != nil || index != lifts.last
                VStack(alignment: .leading, spacing: 0) {
                    if block.isGroup { superset(block, index: index) }
                    else if let movement = block.movements.first { row(movement, block: index) }
                    if open == index, onEdit != nil {
                        BlockEditor(session: editable, index: index, names: names, templates: templates, selected: $selected,
                                    onSwap: { picking = .swap(block: $0, movement: $1, exercise: $2) },
                                    onHowTo: { looking = $0 }, onFill: true)
                            .padding(14)
                            .background(Color.fill.opacity(0.6), in: .rect(cornerRadius: 18))
                            .padding(.bottom, Self.rowPadding)
                            .motionTransition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .overlay(alignment: .bottom) { if ruled { Divider() } }
            }
            if onEdit != nil { addButton("Exercise") { picking = .add } }
        }
        .animation(.settle, value: warm)
        .animation(.settle, value: open)
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            SetStepper(session: editable, selected: $selected, names: names)
                .presentationDetents([.height(250)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(250)))
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: Binding(get: { looking.map(HowToID.init) }, set: { looking = $0?.id })) { item in
            let template = templates.first { $0.slug == item.id }
            HowToSheet(name: names[item.id] ?? item.id, slug: item.id, steps: template?.values("instructions") ?? [], history: history)
        }
        .sheet(item: $picking) { picking in
            let inSession = Set(session.blocks.flatMap(\.movements).map(\.exercise))
            switch picking {
            case .warmup:
                ExercisePicker(title: "Add to the warm-up", excluding: inSession, warmup: true) { slug in change { $0.addWarmup(slug) } }
            case .add:
                ExercisePicker(title: "Add exercise", excluding: inSession) { slug in change { $0.add(slug) } }
            case .swap(let block, let movement, let exercise):
                ExercisePicker(title: "Swap \(names[exercise] ?? exercise)", replacing: exercise, excluding: inSession) { slug in
                    change { $0.swap(block: block, movement: movement, to: slug) }
                }
            }
        }
    }

    /// A ＋ row: a thin ring with a ＋ in the check circles' column, then one grey word (author picked prototype 8: the
    /// verb is the ＋). Inside the open warm-up, which is already on the names' edge, the ring sits flush.
    private func addButton(_ title: String, nested: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: nested || checked == nil ? 8 : Self.gap) {
                Image(systemName: "plus").font(.caption2.weight(.bold)).foregroundStyle(Plate.current.mark)
                    .frame(width: 24, height: 24).overlay(Circle().strokeBorder(Plate.current.mark, lineWidth: 1.5))
                    .frame(width: nested || checked == nil ? nil : Self.column)
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.inkMuted)
            }
            .padding(.vertical, nested ? 4 : Self.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("Add \(title.lowercased())")
    }

    /// The first lift's working weight, the warm-up's target; none for a session without a loaded lift first.
    private var firstLoad: (name: String, load: Double)? {
        session.firstLoad.map { (names[$0.exercise] ?? $0.exercise, $0.load) }
    }

    /// "Rowing Machine, Band Pull-Apart, then ramp to 170", the coach's warm-up (FIT-300), or the computed one:
    /// "9 min · easy cardio, then ramp to 170".
    private func warmupLine(_ first: (name: String, load: Double)?) -> String {
        let ramp = first.map { "ramp to \(Coach.number($0.load))" }
        guard !session.warmup.isEmpty else { return "\(WarmupRamp.minutes(to: first?.load ?? 0)) min · easy cardio, then \(ramp ?? "")" }
        return ([session.warmup.map { names[$0.exercise] ?? $0.exercise }.joined(separator: ", ")] + [ramp.map { "then \($0)" }].compactMap { $0 })
            .joined(separator: ", ")
    }

    /// The fold's chevron, in a small grey circle the check circle's size: right for the warm-up, down for a lift.
    private func chevron(_ name: String, turned: Bool) -> some View {
        Image(systemName: name).font(.caption.weight(.bold)).foregroundStyle(Color.inkMuted)
            .rotationEffect(.degrees(turned ? (name == "chevron.right" ? 90 : 180) : 0))
            .frame(width: 24, height: 24).background(Color.fill, in: .circle)
    }

    private func warmup(_ first: (name: String, load: Double)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { warm.toggle() } label: {
                HStack(spacing: Self.gap) {
                    // In the check circles' column on Today, so the row keeps the list's edge; at the end elsewhere.
                    if checked != nil { chevron("chevron.right", turned: warm).frame(width: Self.column, height: Self.column) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warmupLine(first)).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                        Text("Warm-up").font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                    Spacer(minLength: 0)
                    if checked == nil { chevron("chevron.right", turned: warm).frame(width: Self.column, height: Self.column) }
                }
                .padding(.vertical, Self.rowPadding).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(warm ? "Hides the warm-up" : "Shows the warm-up")
            if warm {
                VStack(alignment: .leading, spacing: 12) {
                    if session.warmup.isEmpty {
                        HStack { Text("Row, bike or walk, easy").foregroundStyle(Color.inkMuted); Spacer(); Text("\(WarmupRamp.cardioMinutes) min").bold() }
                    } else if onEdit != nil {
                        WarmupList(session: editable, names: names).font(.body)
                    } else {
                        ForEach(session.warmup) { movement in
                            HStack { Text(names[movement.exercise] ?? movement.exercise).foregroundStyle(Color.inkMuted); Spacer(); Text(movement.warmupDose).bold() }
                        }
                    }
                    if onEdit != nil {
                        addButton("Exercise", nested: true) { picking = .warmup }
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
                .padding(.leading, inset).padding(.bottom, Self.rowPadding)
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Opens the lift in place, or folds it; where it can't be changed, a tap checks it off as before.
    private func tap(_ block: Int) {
        if onEdit != nil {
            selected = nil
            open = open == block ? nil : block
        } else if let checked {
            toggle(block, in: checked)
        }
    }

    private func superset(_ block: SessionPlan.Block, index blockIndex: Int) -> some View {
        let name = block.movements.map { names[$0.exercise] ?? $0.exercise }.joined(separator: " + ")
        return VStack(alignment: .leading, spacing: 0) {
            Button { tap(blockIndex) } label: {
                HStack {
                    Text("\(Text("SUPERSET").font(.caption.weight(.bold)).tracking(0.6)) · alternate, rest after both")
                        .foregroundStyle(Color.inkMuted)
                    Spacer(minLength: 8)
                    if onEdit != nil { chevron("chevron.down", turned: open == blockIndex) }
                }
                .padding(.top, 12).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.lift")
            .accessibilityLabel(name)
            .accessibilityHint(onEdit != nil ? (open == blockIndex ? "Folds the superset" : "Changes the superset") : "")
            ForEach(Array(block.movements.enumerated()), id: \.element.id) { index, movement in
                row(movement, block: blockIndex, letter: String(UnicodeScalar(UInt8(65 + index))))
            }
            .padding(.leading, 20)
            .background(alignment: .leading) {
                // The bracket: lifts done back to back, as coaches write A1/A2.
                Bracket().stroke(Color.inkFaint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 10).padding(.vertical, 24).padding(.leading, 4)
            }
        }
    }

    private func row(_ movement: SessionPlan.Movement, block: Int, letter: String? = nil) -> some View {
        let done = checked?.wrappedValue.contains(block) == true
        let load = Self.load(movement)
        let name = names[movement.exercise] ?? movement.exercise
        // Simplicity pass (2026-11-11): the "+5 lb" chip alone says it went up; FIT-277's line saying why is gone.
        let up = load.flatMap { load in previous[movement.exercise].map { load - $0 } }.flatMap { $0 > 0 ? $0 : nil }
        let unit = movement.working.first?.value("load_lb_hand") != nil ? "lb each" : "lb"
        return HStack(alignment: .center, spacing: Self.gap) {
            if let checked {
                Button { toggle(block, in: checked) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title2)
                        .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.inkFaint))
                        .frame(width: Self.column, height: Self.column)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Done" : "Check off as done")
            }
            if let letter {
                Text(letter).font(.caption2.weight(.heavy)).foregroundStyle(Color.inkMuted)
                    .frame(width: 18, height: 18).background(Color.surface, in: .circle)
                    .overlay { Circle().stroke(Color.inkFaint, lineWidth: 2) }
            }
            Button { tap(block) } label: {
                // Accessibility sizes stack the row's parts so a lift's name never breaks mid-word.
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name).font(.body.weight(.semibold)).foregroundStyle(done ? Color.inkMuted : Color.ink)
                            if let up {
                                Text("+\(Coach.number(up)) lb").font(.caption.weight(.bold)).foregroundStyle(.tint)
                                    .padding(.horizontal, 7).padding(.vertical, 1).background(.tint.opacity(0.12), in: .capsule)
                            }
                        }
                        Text(Self.dose(movement)).font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    if let load {
                        (Text(Coach.number(load)).font(.display(22, weight: .semibold, relativeTo: .title2))
                         + Text(" \(unit)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .modifier(LiftIdentity(lift: letter == nil, name: name, value: [Self.dose(movement), load.map { "\(Coach.number($0)) \(unit)" }].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(onEdit != nil ? (open == block ? "Folds the lift" : "Changes the lift") : "")
            // A superset's chevron is on its header; a lift's is at the end of its row.
            // TKL-767: the arrow is its own button (it opens and folds the lift, as the row does), 44 pt to tap.
            if onEdit != nil, letter == nil {
                Button { tap(block) } label: {
                    chevron("chevron.down", turned: open == block).frame(width: 44, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -10)
                .accessibilityIdentifier("session.arrow")
                .accessibilityLabel(open == block ? "Fold \(name)" : "Open \(name)")
            }
        }
        .padding(.vertical, Self.rowPadding)
    }

    private func toggle(_ block: Int, in checked: Binding<Set<Int>>) {
        if checked.wrappedValue.contains(block) {
            checked.wrappedValue.remove(block)
        } else {
            checked.wrappedValue.insert(block)
            // Checking off the open lift folds it.
            if open == block { open = nil; selected = nil }
        }
    }

    /// The working weight; none for bodyweight, which a weight stepped down to 0 is.
    static func load(_ movement: SessionPlan.Movement) -> Double? {
        movement.working.first.flatMap { $0.value("load_lb") ?? $0.value("load_lb_hand") }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// "3 sets of 5", "3 sets of 8–12", "3 sets of 40 s".
    static func dose(_ movement: SessionPlan.Movement) -> String {
        let working = movement.working
        guard let first = working.first else { return "" }
        let amount = Coach.amount(reps: first.value("reps"), meters: first.value("distance_m"), seconds: first.value("duration_s")) ?? ""
        return working.count == 1 ? "1 set of \(amount)" : "\(working.count) sets of \(amount)"
    }
}

/// A lift's row is the lift ("session.lift", named for it); a superset's rows are its parts, under the superset's header.
private struct LiftIdentity: ViewModifier {
    let lift: Bool
    let name: String
    let value: String

    func body(content: Content) -> some View {
        if lift {
            content.accessibilityIdentifier("session.lift").accessibilityLabel(name).accessibilityValue(value)
        } else {
            content.accessibilityLabel(name).accessibilityValue(value)
        }
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
