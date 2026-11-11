import SwiftUI

/// "How did it feel?" as a row of choices: workout mode's finish card (FIT-28), and (FIT-378) the sheet after saving
/// lifts ticked off on Today.
struct FeelChoices: View {
    var selected: Feel?
    var pick: (Feel) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Feel.allCases) { feel in
                let on = selected == feel
                Button { pick(feel) } label: {
                    Text(feel.label).font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(on ? Color(.systemBackground) : .primary)
                        .background(on ? Color.primary : .clear, in: .capsule)
                        .overlay { if !on { Capsule().strokeBorder(Color(.tertiaryLabel)) } }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// FIT-378: saving ticked-off lifts asks how it felt, one tap that saves; Skip saves without it.
struct FeelSheet: View {
    var save: (Feel?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("How did it feel?").font(.title3.weight(.bold))
                Spacer()
                Button("Skip") { save(nil) }.font(.body)
            }
            FeelChoices(selected: nil) { save($0) }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1) // four across stay whole
        }
        .padding(.horizontal, 20).padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(150)])
        .presentationDragIndicator(.visible)
    }
}
