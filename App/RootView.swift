import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    /// FIT-201: the pilot's first launch, sign in and join your coach, in place of onboarding.
    @State private var welcoming = false
    @AppStorage("welcomed") private var welcomed = false
    /// FIT-267: the consumer app's first launch: the quiz and its program, then the paywall.
    @State private var picking = false
    @State private var signingInFromQuiz = false
    @Bindable private var navigator = Navigator.shared
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @State private var tab: AppTab = .today
    /// The tab the coach was opened from, so what's said goes back there.
    @State private var lastTab: AppTab = .today
    @State private var coach = CoachInbox()
    @State private var groupsTab = GroupsTab()
    /// FIT-58: an invite link the app was opened with, joined once signed in.
    @State private var invite: Invite?
    @State private var signingInToJoin = false
    @State private var pendingInvite: String?
    @State private var pendingSession: String?
    @State private var pendingProgram: String?
    @State private var pendingCoach: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var joined: Cloud.GroupSummary?

    /// Graphite (FIT-27): monochrome, the label colour is the only accent.
    static let accent = Color.primary

    /// FIT-64: the app's places as tabs, and the coach in the slot iOS 26 keeps for Search.
    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "figure.strengthtraining.traditional", value: AppTab.today) { TodayScreen() }
            Tab("Program", systemImage: "calendar", value: AppTab.program) { ProgramScreen(tabs: [.program]) }
            Tab("Progress", systemImage: "chart.bar", value: AppTab.progress) { ProgramScreen(tabs: [.goals, .wins]) }
            if Pilot.groups, account.isAvailable {
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
            tab = Pilot.inAppAI && LanguageModel.isAvailable ? .coach : .today
            navigator.coach = false
        }
        // The group's name and whether anyone's live: a minute is soon enough, and push says when a workout starts.
        .task(id: account.user?.uid) {
            guard Pilot.groups, account.isAvailable else { return }
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
            if Edition.consumer {
                if profile.programStart == nil { picking = true }
            } else if Pilot.simple {
                if profile.programStart == nil, !welcomed { welcoming = true }
            } else if !profile.isComplete || profile.programStart == nil {
                onboarding = profile
            }
        }
        // FIT-53: a tapped "started a workout" notification opens that group.
        .sheet(item: $navigator.group) { group in
            NavigationStack {
                GroupScreen(summary: group)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { navigator.group = nil } } }
            }
            .tint(Self.accent)
        }
        .sheet(isPresented: Binding(get: { Pilot.sellsPro && pro.paywall }, set: { pro.paywall = $0 })) { PaywallView() }
        .sheet(item: Binding(get: { onboarding == nil ? navigator.gift.map(GiftRef.init) : nil },
                             set: { if $0 == nil { navigator.gift = nil } })) { ref in
            NavigationStack { RedeemGiftView(code: ref.id) }.tint(Self.accent)
        }
        // FIT-281: a plan bought on the web opens the program its quiz picked, with no quiz or paywall in the app.
        .task(id: account.user?.uid) {
            guard let plan = await pro.refreshWebPlan(signedIn: account.user != nil), plan.active, let quiz = plan.quiz,
                  let profile = profiles.first, profile.programStart == nil, let program = ReadyProgram.named(quiz.slug) else { return }
            try? Planner.start(program, days: quiz.days, equipment: ReadyProgram.equipment(Set(quiz.have)), profile: profile, in: context)
            signingInFromQuiz = false
            picking = false
        }
        // FIT-122: Pro from a gift is the account's.
        .task(id: account.user?.uid) {
            await pro.refreshGift(signedIn: account.user != nil)
            // FIT-130: and from a coach, while coached.
            await pro.refreshCoaches(signedIn: account.user != nil)
            await checkOffers()
        }
        // FIT-220: a tapped coaching notification. A changed week is fetched first; a day in this week opens on Today
        // (TodayScreen takes it from there), a later one on Program.
        .onChange(of: navigator.pushed, initial: true) { _, target in
            guard let target else { return }
            navigator.pushed = nil
            switch target.kind {
            case .offer:
                Task { await checkOffers() }
            case .plan, .nudge, .reply:
                if target.kind == .plan { SyncEngine.shared.sync() }
                if let day = target.day, Week.start(of: day) > Week.start(of: .now) {
                    tab = .program
                } else {
                    tab = .today
                    navigator.day = target
                }
            }
        }
        // FIT-131: a program a coach sent waits until it's answered.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkOffers() } }
        }
        // FIT-58: join.barbrabell.com/CODE opens here, on the Join sheet with the code filled in (sign-in first).
        .onOpenURL { url in
            guard account.isAvailable else { return }
            // FIT-122: a gift's link opens Redeem with its code; Redeem asks to sign in.
            if Pilot.gifts, let gift = InviteLink.gift(from: url) {
                navigator.gift = gift
                return
            }
            // FIT-130: a coach's invite asks to allow them; it needs an account.
            if Pilot.coaches, let code = InviteLink.coach(from: url) {
                // FIT-201: first launch answers it in place, signing in first.
                if welcoming {
                    navigator.coachInvite = code
                } else if account.user == nil {
                    pendingCoach = code
                    signingInToJoin = true
                } else {
                    navigator.coachInvite = code
                }
                return
            }
            // FIT-215: friends' sessions, programs and groups wait for the pilot to end.
            guard Pilot.groups else { return }
            // FIT-113: a shared session; it waits for onboarding, if any, then asks before planning anything.
            if let session = InviteLink.session(from: url) {
                if account.user == nil {
                    pendingSession = session
                    signingInToJoin = true
                } else {
                    navigator.session = session
                }
                return
            }
            // FIT-111: a shared program, likewise.
            if let program = InviteLink.program(from: url) {
                if account.user == nil {
                    pendingProgram = program
                    signingInToJoin = true
                } else {
                    navigator.program = program
                }
                return
            }
            guard let code = InviteLink.code(from: url) else { return }
            if account.user == nil {
                pendingInvite = code
                signingInToJoin = true
            } else {
                invite = Invite(code: code)
            }
        }
        .sheet(isPresented: $signingInToJoin, onDismiss: {
            if account.user != nil, let code = pendingInvite { invite = Invite(code: code) }
            if account.user != nil, let session = pendingSession { navigator.session = session }
            if account.user != nil, let program = pendingProgram { navigator.program = program }
            if account.user != nil, let code = pendingCoach { navigator.coachInvite = code }
            pendingCoach = nil
            pendingInvite = nil
            pendingSession = nil
            pendingProgram = nil
        }) {
            SignInSheet(reason: pendingCoach != nil ? "Sign in to train with your coach."
                        : pendingSession != nil || pendingProgram != nil ? "Sign in to train together." : "Sign in to join the group.")
        }
        .sheet(item: Binding(get: { onboarding == nil ? navigator.session.map(SessionRef.init) : nil },
                             set: { if $0 == nil { navigator.session = nil } })) { ref in
            JoinSessionSheet(id: ref.id).tint(Self.accent)
        }
        .sheet(item: Binding(get: { onboarding == nil && !welcoming && navigator.coachInvite == nil ? navigator.offer : nil },
                             set: { if $0 == nil { navigator.offer = nil } })) { offer in
            ProgramOfferSheet(offer: offer).tint(Self.accent)
        }
        .sheet(item: Binding(get: { onboarding == nil && !welcoming ? navigator.coachInvite.map(CoachInviteRef.init) : nil },
                             set: { if $0 == nil { navigator.coachInvite = nil } })) { ref in
            CoachInviteSheet(code: ref.id).tint(Self.accent)
        }
        .sheet(item: Binding(get: { onboarding == nil ? navigator.program.map(ProgramRef.init) : nil },
                             set: { if $0 == nil { navigator.program = nil } })) { ref in
            ProgramStartSheet(id: ref.id).tint(Self.accent)
        }
        // The group opens once the Join sheet has gone: two sheets can't be presented at once.
        .sheet(item: $invite, onDismiss: {
            guard let joined else { return }
            tab = .groups
            navigator.group = joined
            self.joined = nil
        }) { invite in
            NavigationStack {
                JoinGroupSheet(code: invite.code) { group in
                    joined = group
                    self.invite = nil
                }
            }
            .tint(Self.accent)
        }
        .fullScreenCover(isPresented: $picking) {
            ProgramPicker(onDone: { picking = false }, signIn: account.user == nil && account.isAvailable ? { signingInFromQuiz = true } : nil)
                .sheet(isPresented: $signingInFromQuiz) { SignInSheet(reason: "Sign in with the account you started your trial with.") }
                .interactiveDismissDisabled()
                .tint(Self.accent)
        }
        // FIT-267: the consumer app has nothing without the plan: the paywall stays until the trial starts.
        .fullScreenCover(isPresented: Binding(get: { Edition.consumer && pro.checked && !pro.active && !picking && profiles.first?.programStart != nil },
                                              set: { _ in })) {
            PaywallView().interactiveDismissDisabled().tint(Self.accent)
        }
        .fullScreenCover(isPresented: $welcoming) {
            WelcomeView {
                welcomed = true
                welcoming = false
            }
            .interactiveDismissDisabled()
            .tint(Self.accent)
        }
        .fullScreenCover(item: $onboarding) { profile in
            // FIT-83: Pro's trial is offered once the program has just been shown.
            OnboardingView(profile: profile) { started in
                onboarding = nil
                if started, !pro.active { pro.paywall = true }
            }
                .interactiveDismissDisabled()
                .tint(Self.accent)
        }
    }

    /// FIT-131: the oldest program a coach sent that hasn't been answered, if any.
    private func checkOffers() async {
        guard Pilot.coaches, account.user != nil, navigator.offer == nil,
              let offers = try? await Cloud.programOffers() else { return }
        navigator.offer = offers.filter { $0.status == "sent" }.last
    }
}


/// FIT-130: a coach's invite code, as a sheet item.
struct CoachInviteRef: Identifiable {
    let id: String
}

/// FIT-58: the code from an invite link.
struct Invite: Identifiable {
    let code: String
    var id: String { code }
}
