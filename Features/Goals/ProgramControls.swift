import SwiftUI

/// Controls shared by onboarding and the program screen (FIT-38, FIT-39), from the prototype.

/// A row that names something and shows its value; tapping it opens `editor` underneath. A dashed value was heard
/// or suggested and hasn't been touched.
struct ValueRow<Editor: View>: View {
    let name: String
    var detail: String?
    let value: String
    var note: String?
    var dashed = false
    var muted = false
    @Binding var open: Bool
    @ViewBuilder var editor: () -> Editor

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body)
                        if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(value)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .underline(dashed, pattern: .dash, color: .secondary)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(muted ? .secondary : .primary)
                            .contentTransition(.numericText())
                        if let note, !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(value)
            .accessibilityHint(open ? "" : "Change it")
            if open {
                editor()
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
        }
    }
}

/// − value +, for one number.
struct Nudge: View {
    let label: String
    var lessLabel = "Less"
    var moreLabel = "More"
    let less: () -> Void
    let more: () -> Void

    var body: some View {
        HStack {
            button("minus", lessLabel, less)
            Text(label)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
            button("plus", moreLabel, more)
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: .capsule)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color(.systemBackground), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .buttonRepeatBehavior(.enabled)
    }
}

/// A pill that's on or off.
struct Chip: View {
    let title: String
    let on: Bool
    var dashed = false
    var disabled = false
    let toggle: () -> Void

    var body: some View {
        Button { withAnimation(.snappy) { toggle() } } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 15)
                .frame(minHeight: 40)
                .foregroundStyle(on ? Color(.systemBackground) : .primary)
                .background(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.clear), in: .capsule)
                .overlay { if !on { Capsule().strokeBorder(Color(.separator)) } }
                .overlay {
                    if dashed { Capsule().inset(by: -3).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Small caps over a group.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
    }
}

/// Lays out chips in rows, wrapping.
struct Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let height = rows.map { $0.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +)
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += size.width + spacing
        }
        return rows
    }
}

/// The program's weeks as bars: taller as the work climbs, deloads short and quiet, the test week tallest.
/// On the program screen the week shown is solid and this week has a dot over it.
struct PhaseBars: View {
    let weeks: [ProgramWeek]
    var current: Int?
    var selected: Int?
    var tap: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(weeks.indices, id: \.self) { index in
                    let week = weeks[index]
                    VStack(spacing: 2) {
                        ZStack {
                            if index == current { Circle().fill(.secondary).frame(width: 4, height: 4) }
                            else { Text(week.travel ? "✈︎" : " ").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .frame(height: 11)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(index))
                            .frame(height: Self.height(week))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                    .onTapGesture { tap?(index) }
                    .accessibilityElement()
                    .accessibilityLabel("Week \(index + 1)" + (week.kind == .deload ? ", deload" : week.kind == .test ? ", test" : "")
                        + (week.travel ? ", travel" : "") + (index == current ? ", this week" : ""))
                    .accessibilityAddTraits(tap == nil ? [] : .isButton)
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                }
            }
            .frame(height: 42, alignment: .bottom)
            // Sized by its text, so a larger text size pushes what's below down instead of running under it.
            PhaseLabels(count: weeks.count, starts: groups.map(\.start)) {
                ForEach(groups, id: \.start) { group in
                    Text(group.phase.rawValue.capitalized)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private struct Group { var phase: ProgramPhase; var start: Int; var count: Int }

    private var groups: [Group] {
        var groups: [Group] = []
        for (index, week) in weeks.enumerated() {
            if groups.last?.phase == week.phase { groups[groups.count - 1].count += 1 } else { groups.append(Group(phase: week.phase, start: index, count: 1)) }
        }
        return groups
    }

    static func height(_ week: ProgramWeek) -> CGFloat {
        switch week.kind {
        case .deload: 10
        case .test: 30
        default: week.phase == .base ? 14 : week.phase == .build ? 20 : 25
        }
    }

    private func color(_ index: Int) -> Color {
        let week = weeks[index]
        guard let selected else { return week.kind == .deload ? Color(.quaternaryLabel) : Color.primary.opacity(week.phase == .base ? 0.45 : week.phase == .build ? 0.7 : 1) }
        if index == selected { return .primary }
        return week.kind == .deload ? Color(.quaternaryLabel) : Color(.tertiaryLabel)
    }
}

/// Each phase's name under the bar its phase starts at.
private struct PhaseLabels: Layout {
    let count: Int
    let starts: [Int]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where starts.indices.contains(index) {
            let x = bounds.minX + bounds.width * CGFloat(starts[index]) / CGFloat(max(1, count))
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .unspecified)
        }
    }
}

/// Seven day circles, Monday first; at least one stays on.
struct DayCircles: View {
    @Binding var days: [Int]
    var dashed = false
    var minimum = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    withAnimation(.snappy) {
                        if on { if days.count > minimum { days.removeAll { $0 == day } } } else { days = (days + [day]).sorted() }
                    }
                } label: {
                    ZStack {
                        Circle().fill(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.clear))
                        if !on { Circle().strokeBorder(Color(.separator)) }
                        if on && dashed {
                            Circle().inset(by: -3).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        Text(ProfileEditor.weekdays[day].prefix(1))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? Color(.systemBackground) : .primary)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ProfileEditor.weekdays[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
