import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query private var goals: [Goal]
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    @State private var suggesting = false

    /// FIT-19 prototype accent #F06418.
    static let accent = Color(red: 0.94, green: 0.39, blue: 0.09)

    var body: some View {
        TabView {
            Tab("Today", systemImage: "calendar") { TodayScreen() }
            Tab("Goals", systemImage: "target") { GoalsScreen() }
            Tab("Log", systemImage: "square.and.pencil") { LogScreen() }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") { ProgressScreen() }
        }
        .tint(Self.accent)
        // Onboarding (FIT-4): settings once, then suggested goals. The profile is inserted up front so edits
        // are observed, and an unfinished one resumes on the next launch.
        .onAppear {
            let profile = profiles.first ?? {
                let profile = Profile(age: 0, weightLb: 0)
                context.insert(profile)
                return profile
            }()
            if !profile.isComplete { onboarding = profile }
        }
        .fullScreenCover(item: $onboarding) { profile in
            NavigationStack {
                ProfileEditor(profile: profile, isNew: true) { suggesting = true }
                    .navigationDestination(isPresented: $suggesting) {
                        SuggestedGoalsView(profile: profile, existing: Set(goals.map(\.metric))) { onboarding = nil }
                            .navigationBarBackButtonHidden()
                    }
            }
            .interactiveDismissDisabled()
            .tint(Self.accent)
        }
    }
}
