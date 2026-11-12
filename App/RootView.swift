import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// FIT-381: anything planned at all, one row is enough.
    @Query(RootView.anyPlanned) private var planned: [PlannedActivity]
    static var anyPlanned: FetchDescriptor<PlannedActivity> {
        var descriptor = FetchDescriptor<PlannedActivity>()
        descriptor.fetchLimit = 1
        return descriptor
    }
    /// FIT-424: the last thing logged, so logging this week's last session saves next week.
    @Query(RootView.lastLogged) private var lastLog: [LogEntry]
    static var lastLogged: FetchDescriptor<LogEntry> {
        var descriptor = FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }
    /// FIT-424: the day weeks were last kept planned for; it moves on when the app comes back on a new day or at midnight.
    @State private var planDay = Calendar.current.startOfDay(for: .now)
    /// Set while onboarding; presenting by item hands the profile straight to the cover.
    @State private var onboarding: Profile?
    /// FIT-201: the pilot's first launch, sign in and join your coach, in place of onboarding.
    @State private var welcoming = false
    @AppStorage("welcomed") private var welcomed = false
    /// FIT-413: the launch splash, once per cold launch; resuming from the background keeps this view and its state.
    @State private var splash = true
    /// The first launch's splash plays on the Welcome cover, over this one held at its first frame.
    @State private var welcomeSplash = false
    /// FIT-414: Welcome's promise rises in as that splash's mark lifts.
    @State private var welcomeRevealed = false
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
    /// FIT-298: coach mode, for someone who came in as a coach or has clients.
    @State private var roster = Roster.restored()
    @AppStorage(Roster.coachingKey) private var coachUID = ""

    /// FIT-445: coach, coached client or lifter on their own, and so the tabs. FIT-381: Today, Program and Progress come
    /// with a program of their own ("Train on my own too", or Program on You), a planned day, or a coach of their own.
    private var mode: AppMode {
        var coach = account.user.map { $0.uid == coachUID } ?? false
        #if DEBUG
        // `-sampleClients YES`: a coach with a made-up roster. A client with one stands for a sample client left from
        // before FIT-445, which the launch's check now clears, so it never makes them a coach.
        if Roster.sample && pro.coaches.isEmpty { coach = true }
        #endif
        return AppMode(coach: coach, trains: trains)
    }
    private var trains: Bool { profiles.first?.programStart != nil || !planned.isEmpty || !pro.coaches.isEmpty }

    /// FIT-297: the plate colour picked on You (design system v2); Blue 20 until one is picked.
    static var accent: Color { Plate.current.accent }
    @AppStorage(Plate.key) private var plate = Plate.blue.rawValue

    var body: some View {
        tabs
        .overlay {
            if splash {
                Splash(plays: !welcomesAtLaunch) { splash = false }.transition(.opacity)
            }
        }
        .environment(coach)
        .environment(roster)
        // FIT-298: a coach opens on their clients; one who has clients is a coach, whichever door they came in by.
        .onChange(of: mode.coach, initial: true) { _, coach in if coach { tab = .clients } }
        // FIT-445: never left on a tab that isn't there for them.
        .onChange(of: mode.tabs, initial: true) { _, _ in if let other = mode.replacing(tab) { tab = other } }
        .onChange(of: tab) { _, new in if new != .coach { lastTab = new } }
        // FIT-430: signing out, or deleting the account, goes back to the three doors; the next account's door decides
        // coach mode. Only a signed-in account going away: the launch's restore starts from nil.
        .onChange(of: account.user?.uid) { old, new in
            guard Pilot.simple, old != nil, new == nil else { return }
            coachUID = ""
            tab = .today
            welcomed = false
            welcoming = true
        }
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
            if Pilot.simple {
                if welcomesAtLaunch {
                    // At once rather than sliding up, so its splash takes over from this one without a seam.
                    welcomeSplash = splash
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { welcoming = true }
                }
                #if DEBUG
                if Roster.sample {
                    roster = Roster(clients: Roster.samples(), invites: [Cloud.ClientInvite(
                        code: "K7Q2MX", url: "https://join.barbrabell.com/K7Q2MX", createdAt: Date.now.addingTimeInterval(-86_400).ISO8601Format(), client: "Jess Park")])
                    // FIT-338: last looked at four days ago, so Mike's Sunday note is unread.
                    for client in roster.clients { roster.markSeen(client.id, at: .now.addingTimeInterval(-4 * 86_400)) }
                }
                #endif
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
        .sheet(isPresented: Binding(get: { Pilot.sellsPro && pro.paywall }, set: { pro.paywall = $0 })) { PaywallView(plan: .lifter) }
        .sheet(item: Binding(get: { onboarding == nil ? navigator.gift.map(GiftRef.init) : nil },
                             set: { if $0 == nil { navigator.gift = nil } })) { ref in
            NavigationStack { RedeemGiftView(code: ref.id) }.tint(Self.accent)
        }
        // FIT-122: Pro from a gift is the account's.
        .task(id: account.user?.uid) {
            await pro.refreshGift(signedIn: account.user != nil)
            // FIT-422: lifter Pro decides who gets AI-designed weeks. FIT-437: the App Store's purchases on this phone are
            // registered to the account, and the server's plans (either store) read.
            await pro.signedIn(account.user?.uid)
            // FIT-130: and from a coach, while coached.
            await pro.refreshCoaches(signedIn: account.user != nil)
            // After the coaches, so a client's saved coach mode is checked knowing they train with one.
            await checkCoaching()
            await checkOffers()
        }
        // FIT-220: a tapped coaching notification. A changed week is fetched first; a day in this week opens on Today
        // (TodayScreen takes it from there), a later one on Program.
        .onChange(of: navigator.pushed, initial: true) { _, target in
            guard let target else { return }
            navigator.pushed = nil
            // FIT-413: a tapped notification goes straight to what it's about.
            withAnimation(.tap) { splash = false }
            switch target.kind {
            case .ended:
                Task { await pro.refreshCoaches(signedIn: account.user != nil) }
            case .offer:
                Task { await checkOffers() }
            case .client:
                // Only coaches are sent these; the tab is there only if the mode says so (FIT-445).
                if let user = account.user { coachUID = user.uid }
                guard mode.tabs.contains(.clients) else { return }
                tab = .clients
                navigator.clientDay = target
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
        // FIT-424: weeks are kept planned here, whichever tab is open: on launch, a new day, a change of mode or program,
        // and a session logged. FIT-422: code plans a free lifter's week and the AI redesigns a Pro lifter's; a coach's
        // client gets the coach's.
        .task(id: "\(planDay) \(profiles.first?.plansItself == true) \(profiles.first?.programSlug ?? "") \(pro.lifterPro) \(pro.coaches.isEmpty) \(lastLog.first?.id.uuidString ?? "")") {
            guard let source = pro.weekSource(hasProgram: profiles.first?.programStart != nil), source.plansItself else { return }
            do {
                try Planner.keepWeeks(in: context)
            } catch {
                planningFailed(error)
            }
            // FIT-426: a Pro lifter's weeks are designed by the AI, this one and next once it's saved, so it lands
            // before it starts. A free lifter's never reach a model.
            guard source == .ai else { return }
            #if DEBUG
            // FIT-445: a UI test's role keeps the week code planned, the same every run.
            if DebugRole.uiTesting { return }
            #endif
            let model = LanguageModel.weeks(signedIn: account.user != nil)
            await Planner.design(in: context, model: model)
            await Planner.design(weekOf: Calendar.current.date(byAdding: .day, value: 7, to: .now)!, in: context, model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            planDay = Calendar.current.startOfDay(for: .now)
        }
        // FIT-131: a program a coach sent waits until it's answered.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            planDay = Calendar.current.startOfDay(for: .now)
            Task {
                await checkOffers()
                // FIT-383: coaching that ended on another device, or by the coach, goes without a relaunch.
                await pro.refreshCoaches(signedIn: account.user != nil)
                await pro.refreshServerPlans(signedIn: account.user != nil)
            }
        }
        // FIT-58: join.barbrabell.com/CODE opens here, on the Join sheet with the code filled in (sign-in first).
        .onOpenURL { url in
            withAnimation(.tap) { splash = false }
            guard account.isAvailable else { return }
            // FIT-122: a gift's link opens Redeem with its code; Redeem asks to sign in.
            if Pilot.gifts, let gift = InviteLink.gift(from: url) {
                navigator.gift = gift
                return
            }
            // FIT-130: a coach's invite asks to allow them; it needs an account.
            if let code = InviteLink.coach(from: url) {
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
        .fullScreenCover(isPresented: $welcoming) {
            WelcomeView(revealed: !welcomeSplash || welcomeRevealed) {
                welcomed = true
                welcoming = false
                splash = false
            }
            .overlay {
                if welcomeSplash { Splash(first: true, lifting: { welcomeRevealed = true }) { welcomeSplash = false } }
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

    /// FIT-64: the app's places as tabs, and the coach in the slot iOS 26 keeps for Search.
    private var tabs: some View {
        TabView(selection: $tab) {
            if mode.tabs.contains(.clients) {
                // FIT-338: how many clients wrote since the coach last looked.
                Tab("Clients", systemImage: "person.2", value: AppTab.clients) { ClientsScreen() }
                    .badge(roster.unread)
            }
            if mode.tabs.contains(.today) {
                Tab("Today", systemImage: "figure.strengthtraining.traditional", value: AppTab.today) { TodayScreen() }
                Tab("Program", systemImage: "calendar", value: AppTab.program) { ProgramScreen(tabs: [.program]) }
                Tab("Progress", systemImage: "chart.bar", value: AppTab.progress) { ProgramScreen(tabs: [.goals, .wins, .history]) }
            }
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
    }

    /// FIT-201: the pilot's first launch opens on Welcome, until there's a program or it's been through once.
    private var welcomesAtLaunch: Bool {
        guard Pilot.simple else { return false }
        #if DEBUG
        // `-welcome YES` opens the first launch over any program, to look at it (FIT-296).
        if UserDefaults.standard.bool(forKey: "welcome") { return true }
        #endif
        return profiles.first?.programStart == nil && !welcomed
    }

    /// FIT-424: the last good week stands. Today says so once, and the error goes to the author with the crash reports.
    private func planningFailed(_ error: Error) {
        Planner.designing.trouble = "Couldn't plan your week. The last one stands."
        let report = ["planning": String(describing: error), "day": planDay.ISO8601Format()]
        if let data = try? JSONEncoder().encode(report) { Diagnostics.keep(data) }
        Task { await Diagnostics.send() }
    }

    /// FIT-298: someone with real clients is a coach, whichever door they came in by. FIT-445: asked without a sample
    /// client, and a sample doesn't count, so this never makes anyone a coach; and coach mode saved before FIT-445,
    /// when it did, is checked once (`AppMode.keepsSavedCoaching`).
    private func checkCoaching() async {
        guard let user = account.user, coachUID != user.uid else { return }
        let saved = UserDefaults.standard
        let legacy = saved.string(forKey: Roster.legacyCoachingKey) == user.uid
        // A coach who doesn't train keeps it at once, offline too.
        if legacy && AppMode.keepsSavedCoaching(clients: [], invites: 0, trains: trains) {
            coachUID = user.uid
            return saved.removeObject(forKey: Roster.legacyCoachingKey)
        }
        guard let clients = try? await Cloud.myClients(sample: false) else { return }
        if AppMode.coaches(clients) {
            coachUID = user.uid
        } else if legacy {
            // Unanswered, it's asked again next launch.
            guard let invites = try? await Cloud.myInvites() else { return }
            if AppMode.keepsSavedCoaching(clients: clients, invites: invites.count, trains: trains) { coachUID = user.uid }
        }
        if legacy { saved.removeObject(forKey: Roster.legacyCoachingKey) }
    }

    /// FIT-131: the oldest program a coach sent that hasn't been answered, if any.
    private func checkOffers() async {
        guard account.user != nil, navigator.offer == nil,
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
