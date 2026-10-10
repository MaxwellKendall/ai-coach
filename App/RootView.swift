import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    @Bindable private var navigator = Navigator.shared
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @State private var tab: AppTab = .today
    /// The tab the coach was opened from, so what's said goes back there.
    @State private var lastTab: AppTab = .today
    @State private var coach = CoachInbox()
    @State private var groupsTab = GroupsTab()

    /// Graphite (FIT-27): monochrome, the label colour is the only accent.
    static let accent = Color.primary

    /// FIT-64: the app's places as tabs, and the coach in the slot iOS 26 keeps for Search.
    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "figure.strengthtraining.traditional", value: AppTab.today) { TodayScreen() }
            Tab("Program", systemImage: "calendar", value: AppTab.program) { ProgramScreen(tabs: [.program]) }
            Tab("Progress", systemImage: "chart.bar", value: AppTab.progress) { ProgramScreen(tabs: [.goals, .wins]) }
            if account.isAvailable {
                Tab(groupsTab.title, systemImage: "person.2", value: AppTab.groups) { NavigationStack { GroupsScreen() } }
                    .badge(groupsTab.live ? Text("Live") : nil)
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
        // FIT-65: Talk to Coach opens the coach, which starts listening; without Apple Intelligence, Today.
        .onChange(of: navigator.coach, initial: true) { _, wanted in
            guard wanted else { return }
            tab = LanguageModel.isAvailable ? .coach : .today
            navigator.coach = false
        }
        // The group's name and whether anyone's live: a minute is soon enough, and push says when a workout starts.
        .task(id: account.user?.uid) {
            guard account.isAvailable else { return }
            while !Task.isCancelled {
                await groupsTab.refresh(me: account.user?.uid)
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
        .sheet(isPresented: Binding(get: { pro.paywall }, set: { pro.paywall = $0 })) { PaywallView() }
        .fullScreenCover(item: $onboarding) { profile in
            // FIT-83: Pro's trial is offered once the program has just been shown.
            OnboardingView(profile: profile) {
                onboarding = nil
                if !pro.active { pro.paywall = true }
            }
                .interactiveDismissDisabled()
                .tint(Self.accent)
        }
    }
}
