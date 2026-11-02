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

/// FIT-319: the exercise's demo on YouTube, when it has one.
struct HowToVideo: View {
    let slug: String

    var body: some View {
        if let url = ExerciseVideos.bundled[slug] {
            Link(destination: url) { Label("Watch a Demo", systemImage: "play.rectangle") }
        }
    }
}

/// The how-to for one exercise, from a session (FIT-75).
struct HowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let slug: String
    let steps: [String]

    var body: some View {
        NavigationStack {
            List {
                if ExerciseVideos.bundled[slug] != nil { Section { HowToVideo(slug: slug) } }
                if !steps.isEmpty { Section { HowToSteps(steps: steps) } }
            }
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
