import SwiftUI

/// FIT-75: an exercise's how-to steps (free-exercise-db), numbered.
struct HowToSteps: View {
    let steps: [String]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index + 1)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The how-to for one exercise, from a session (FIT-75).
struct HowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let steps: [String]

    var body: some View {
        NavigationStack {
            List { Section { HowToSteps(steps: steps) } }
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
