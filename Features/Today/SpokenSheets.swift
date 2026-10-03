import SwiftUI

/// Prototype board 2: what you said, what the rules would change, Apply or keep the plan.
struct ProposalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: Proposal
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("“\(proposal.said)”").font(.subheadline).foregroundStyle(.secondary)
                    Text(proposal.title).font(.system(size: 26, weight: .bold)).tracking(-0.3).padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 0) {
                        ForEach(proposal.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(line.mark.rawValue).foregroundStyle(.tertiary).frame(width: 14)
                                Text(line.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .strikethrough(line.mark == .removed)
                                    .foregroundStyle(line.mark == .removed ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .overlay(alignment: .top) { Divider() }
                        }
                    }
                    .overlay(alignment: .bottom) { Divider() }
                    .padding(.top, 18)
                    Text(proposal.footnote).font(.footnote).foregroundStyle(.tertiary).padding(.top, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 22)
            Button {
                onApply()
                dismiss()
            } label: {
                Text("Apply").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            Button(proposal.keep) { dismiss() }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 6)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 8)
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }
}

/// Prototype board 6: a session logged by voice, matched to the plan. Only the differences are shown, dashed
/// as heard, with −/+ in case they were heard wrong. Save is the only way anything is stored.
struct SpokenCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    let said: String
    let title: String
    @State var draft: WorkoutDraft
    let changed: [Int]
    let names: [String: String]
    let onSave: (WorkoutDraft) -> Void

    var body: some View {
        let asPlanned = draft.rows.count - changed.count
        VStack(alignment: .leading, spacing: 0) {
            Text("“\(said)”").font(.subheadline).foregroundStyle(.secondary)
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3).padding(.top, 6)
            Text(changed.isEmpty ? "All \(draft.rows.count) sets as planned."
                 : "\(asPlanned) \(asPlanned == 1 ? "set" : "sets") as planned, and \(changed.count == 1 ? "one change" : "\(changed.count) changes"):")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            if !changed.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(changed, id: \.self, content: changeRow)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .overlay(alignment: .bottom) { Divider() }
                .padding(.top, 18)
                Text("Matched to today’s plan. Dashed is what I heard; tap − or + if I got it wrong.")
                    .font(.footnote).foregroundStyle(.tertiary).padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 22)
            Button {
                onSave(draft)
                dismiss()
            } label: {
                Text("Save").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            Button("Cancel") { dismiss() }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 6)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 8)
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }

    private func changeRow(_ index: Int) -> some View {
        let row = draft.rows[index]
        let number = draft.rows[..<index].filter { $0.exercise == row.exercise }.count + 1
        let load = row.loadMetric != nil && row.load != row.plannedLoad
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(names[row.exercise] ?? row.exercise), set \(number)")
                Text("Plan was \(plan(row))").font(.footnote).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if row.value != row.plannedValue { stepper(index, load: false) }
            if load { stepper(index, load: true) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }

    private func plan(_ row: SetRow) -> String {
        let value = row.plannedValue.map { Coach.number($0) + (row.metric == "reps" ? "" : " " + (SetRow.units[row.metric] ?? "")) } ?? "–"
        return value + (row.plannedLoad.map { " × \(Coach.number($0)) lb" } ?? "")
    }

    private func stepper(_ index: Int, load: Bool) -> some View {
        let row = draft.rows[index]
        return HStack(spacing: 4) {
            round("minus", load ? "5 lb less" : "Fewer") { draft.adjust([index], load: load, by: -1); draft.rows[index].heard = true }
            (Text(Coach.number((load ? row.load : row.value) ?? 0))
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                + Text(load ? " lb" : row.metric == "reps" ? " reps" : " " + (SetRow.units[row.metric] ?? ""))
                .font(.footnote).foregroundStyle(.secondary))
                .contentTransition(.numericText())
                .frame(minWidth: 54)
                .overlay(alignment: .bottom) {
                    Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.tertiary)
                        .frame(height: 1.5).offset(y: 3)
                }
            round("plus", load ? "5 lb more" : "More") { draft.adjust([index], load: load, by: 1); draft.rows[index].heard = true }
        }
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
