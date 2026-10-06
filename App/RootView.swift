import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    @Bindable private var navigator = Navigator.shared
    @Environment(Account.self) private var account
    @State private var tab: AppTab = .today
    /// The tab the coach was opened from, so what's said goes back there.
    @State private var lastTab: AppTab = .today
    @State private var coach = CoachInbox()

    /// Graphite (FIT-27): monochrome, the label colour is the only accent.
    static let accent = Color.primary

    /// FIT-64: the app's places as tabs, and the coach in the slot iOS 26 keeps for Search.
    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "figure.strengthtraining.traditional", value: AppTab.today) { TodayScreen() }
            Tab("Program", systemImage: "calendar", value: AppTab.program) { ProgramScreen(tabs: [.program]) }
            Tab("Progress", systemImage: "chart.bar", value: AppTab.progress) { ProgramScreen(tabs: [.goals, .wins]) }
            if account.isAvailable {
                Tab("Groups", systemImage: "person.2", value: AppTab.groups) { NavigationStack { GroupsScreen() } }
            }
            // Principle 5: without Apple Intelligence there's no coach; every manual path stays.
            if LanguageModel.isAvailable {
                Tab("Coach", systemImage: "sparkles", value: AppTab.coach, role: .search) {
                    CoachScreen(from: lastTab) { said, target in
                        coach.request = CoachInbox.Request(said: said, target: target)
                        tab = target
                    }
                }
            }
        }
        .environment(coach)
        .onChange(of: tab) { _, new in if new != .coach { lastTab = new } }
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
