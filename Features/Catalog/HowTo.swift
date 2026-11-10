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

/// FIT-318: the exercise's start and end photos, side by side; nothing while they load or when there are none.
/// FIT-348: its looping demo clip instead, when it has one.
struct HowToPhotos: View {
    let slug: String

    static func shows(_ slug: String) -> Bool { ExerciseDemos.url(slug) != nil || !ExercisePhotos.urls(slug).isEmpty }

    var body: some View {
        let urls = ExercisePhotos.urls(slug)
        if let demo = ExerciseDemos.url(slug) {
            LoopingVideo(url: demo)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Video: one rep of the movement")
        } else if !urls.isEmpty {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos: the start and end of the movement")
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
                if HowToPhotos.shows(slug) {
                    Section { HowToPhotos(slug: slug) }.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
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
