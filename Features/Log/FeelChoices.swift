import SwiftUI

/// "How did it feel?" as a row of choices: workout mode's finish card (FIT-28), and (FIT-378) the sheet after saving
/// lifts ticked off on Today. TKL-934: the chosen capsule slides between options with matched geometry and a tick.
struct FeelChoices: View {
    var selected: Feel?
    var reduceMotion = false
    var pick: (Feel) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Namespace private var selection

    private var reduced: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Feel.allCases) { feel in
                let on = selected == feel
                Button {
                    withAnimation(reduced ? .out : .tap) { pick(feel) }
                } label: {
                    Text(feel.label)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.canvas : Color.ink)
                        .background {
                            if on {
                                if reduced {
                                    Capsule().fill(Color.ink)
                                } else {
                                    Capsule().fill(Color.ink)
                                        .matchedGeometryEffect(id: "feel.selected", in: selection)
                                }
                            } else {
                                Capsule().fill(Color.fill)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.tick, trigger: selected)
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
