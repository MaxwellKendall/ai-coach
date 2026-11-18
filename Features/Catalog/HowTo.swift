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
/// FIT-348: its looping demo clip instead, when it has one. FIT-447: the photos again if the clip can't load.
struct HowToPhotos: View {
    let slug: String

    static func shows(_ slug: String) -> Bool { ExerciseDemos.url(slug) != nil || !ExercisePhotos.urls(slug).isEmpty }

    var body: some View {
        DemoClip(slug: slug) { Self.photos(slug) }
    }

    /// The start and end photos alone. TKL-793: the copies in the app when it has them (exercises with a demo clip), so
    /// they show offline; else from the site.
    @ViewBuilder static func photos(_ slug: String) -> some View {
        let local = ExercisePhotos.local(slug).compactMap { UIImage(contentsOfFile: $0.path()) }
        let urls = ExercisePhotos.urls(slug)
        if !local.isEmpty, local.count == urls.count {
            HStack(spacing: 8) {
                ForEach(Array(local.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 12))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos: the start and end of the movement")
            .accessibilityValue("\(local.count) shown")
            .accessibilityIdentifier("howto.photos")
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
            .accessibilityIdentifier("howto.photos")
        }
    }
}

/// FIT-319: the exercise's demo on YouTube, when it has one. TKL-793: a quiet link at the bottom of the how-to.
struct HowToVideo: View {
    let slug: String

    var body: some View {
        if let url = ExerciseVideos.bundled[slug] {
            Link(destination: url) { Label("Watch on YouTube", systemImage: "play.rectangle") }
                .font(.footnote).foregroundStyle(Color.inkMuted)
        }
    }
}

/// TKL-793: the demo at the top of the how-to, square, playing in place: tap pauses it, Slow plays it at half speed.
/// Without a clip (or offline before it was cached) the photos show, and it says when that's because you're offline.
struct HowToDemo: View {
    let slug: String
    @State private var paused = false
    @State private var slow = false
    @State private var unavailable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if ExerciseDemos.url(slug) != nil {
            let controls = !reduceMotion && !unavailable
            DemoClip(slug: slug, corner: 16, paused: paused, slow: slow, notesOffline: true, unavailable: $unavailable) {
                HowToPhotos.photos(slug)
            }
                .overlay(alignment: .center) {
                    if paused, controls {
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(.black.opacity(0.5), in: .circle)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if controls {
                        Button { slow.toggle() } label: {
                            Label("Slow", systemImage: "tortoise.fill").font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(slow ? Color.black : Color.white)
                                .background(slow ? AnyShapeStyle(Color.white) : AnyShapeStyle(.black.opacity(0.5)), in: .capsule)
                        }
                        .buttonStyle(.plain).padding(10)
                        .accessibilityIdentifier("howto.slow")
                        .accessibilityLabel(slow ? "Normal speed" : "Slow")
                        .accessibilityAddTraits(slow ? .isSelected : [])
                    }
                }
                .contentShape(.rect)
                .onTapGesture { if controls { paused.toggle() } }
                .accessibilityAction(named: paused ? "Play" : "Pause") { paused.toggle() }
        } else {
            HowToPhotos.photos(slug)
        }
    }
}

/// One exercise in the how-to sheet.
struct HowToPage: Identifiable, Equatable {
    var slug: String
    var name: String
    var steps: [String]
    var id: String { slug }

    /// The session's lifts, in order (TKL-793), named and with their steps from the catalog.
    static func pages(_ session: SessionPlan, names: [String: String], templates: [Template]) -> [HowToPage] {
        session.howToOrder.map { slug in
            let template = templates.first { $0.slug == slug }
            return HowToPage(slug: slug, name: names[slug] ?? template?.name ?? slug, steps: template?.values("instructions") ?? [])
        }
    }
}

/// The how-to for one exercise, from a session (FIT-75). TKL-793: it leads with the demo, then Last time, the steps, and
/// YouTube as a quiet link; swiping left and right pages through the session's exercises, with dots.
struct HowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pages: [HowToPage]
    /// FIT-356: your last sessions of it, under the demo.
    var history = false
    @State private var current: String

    init(pages: [HowToPage], start: String, history: Bool = false) {
        // An exercise opened from outside the session's lifts (a warm-up item) still gets its page.
        self.pages = pages.contains { $0.slug == start } ? pages : [HowToPage(slug: start, name: start, steps: [])] + pages
        self.history = history
        _current = State(initialValue: start)
    }

    /// One exercise on its own.
    init(name: String, slug: String, steps: [String], history: Bool = false) {
        self.init(pages: [HowToPage(slug: slug, name: name, steps: steps)], start: slug, history: history)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(pages) { page in
                    HowToPageView(page: page, history: history).tag(page.slug)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Color(.systemGroupedBackground))
            .navigationTitle(pages.first { $0.slug == current }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

private struct HowToPageView: View {
    let page: HowToPage
    let history: Bool

    var body: some View {
        List {
            if HowToPhotos.shows(page.slug) {
                Section { HowToDemo(slug: page.slug) }.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            if history { ExerciseHistorySection(slug: page.slug, limit: 3, title: "Last time") }
            if !page.steps.isEmpty { Section { HowToSteps(steps: page.steps) } }
            if ExerciseVideos.bundled[page.slug] != nil {
                Section { HowToVideo(slug: page.slug) }.listRowBackground(Color.clear)
            }
            // Room above the page dots.
            Color.clear.frame(height: 24).listRowBackground(Color.clear)
        }
        .accessibilityIdentifier("howto.page")
    }
}
