import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    @Bindable private var navigator = Navigator.shared

    /// Graphite (FIT-27): monochrome, the label colour is the only accent.
    static let accent = Color.primary

    var body: some View {
        TodayScreen()
        .tint(Self.accent)
        // Onboarding (FIT-38): until there's a program. The profile is inserted up front so edits are observed,
        // and an unfinished one resumes on the next launch.
        .onAppear {
            let profile = profiles.first ?? {
                let profile = Profile(age: 0, weightLb: 0)
                context.insert(profile)
                return profile
            }()
            if !profile.isComplete || profile.programStart == nil { onboarding = profile }
        }
        // FIT-53: a tapped "started a workout" notification opens that group.
        .sheet(item: $navigator.group) { group in
            NavigationStack {
                GroupScreen(summary: group)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { navigator.group = nil } } }
            }
            .tint(Self.accent)
        }
        .fullScreenCover(item: $onboarding) { profile in
            OnboardingView(profile: profile) { onboarding = nil }
                .interactiveDismissDisabled()
                .tint(Self.accent)
        }
    }
}
