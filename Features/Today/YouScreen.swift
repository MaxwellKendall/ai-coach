import SwiftUI
import SwiftData

/// The account and the library, top right on Today. Program, Progress and Groups are tabs since FIT-64.
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @State private var signingIn = false
    @State private var stopping: Cloud.Person?
    @State private var failure: String?
    @State private var joining = false
    @State private var nudges = Push.nudges
    @Query private var profiles: [Profile]
    /// FIT-230: picking or changing the ready-made program.
    @State private var choosing = false
    @AppStorage(Plate.key) private var plate = Plate.blue.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
                    // FIT-297: the app's colour, after the competition bumper plates.
                    Picker(selection: $plate) {
                        ForEach(Plate.allCases) { plate in Text(plate.name).tag(plate.rawValue) }
                    } label: { Label("Colour", systemImage: "circle.lefthalf.filled") }
                    #if DEBUG
                    if Pilot.inAppAI {
                        NavigationLink { VoiceLogView() } label: { Label("Spoken attempts", systemImage: "waveform") }
                    }
                    // Pro without buying, kept across launches, for the author's own phone (`-pro YES` lasts one launch).
                    if Pilot.sellsPro {
                        Toggle(isOn: Binding(get: { UserDefaults.standard.bool(forKey: "pro") }, set: { on in
                            UserDefaults.standard.set(on, forKey: "pro")
                            Task { await pro.refresh() }
                        })) { Label("Pro (debug)", systemImage: "star") }
                    }
                    BackendPicker()
                    #endif
                    // FIT-122: a year of Pro bought as a gift on the web.
                    if Pilot.gifts, account.isAvailable {
                        NavigationLink { RedeemGiftView() } label: { Label("Redeem a gift", systemImage: "gift") }
                    }
                }
                // FIT-230: without a coach, the ready-made program being followed, and a way to pick another.
                if pro.coaches.isEmpty {
                    Section {
                        Button { choosing = true } label: {
                            LabeledContent {
                                Text(ReadyProgram.named(profiles.first?.programSlug)?.name ?? "Pick One")
                            } label: {
                                Label("Program", systemImage: "list.bullet.rectangle")
                            }
                        }
                        .tint(.primary)
                    }
                }
                // FIT-126: signed out, a way in: the account keeps the program backed up and on the web.
                if account.user == nil, account.isAvailable {
                    Section {
                        Button { signingIn = true } label: {
                            Label("Sign In", systemImage: "person.crop.circle")
                        }
                    } footer: {
                        Text("Back up your program and see it on the web.")
                    }
                }
                // FIT-130: who coaches me, and the way to stop.
                if account.user != nil, !pro.coaches.isEmpty {
                    Section {
                        ForEach(pro.coaches) { coach in
                            HStack {
                                Label(coach.name.map { "Coached by \($0)" } ?? "You have a coach", systemImage: "person.2")
                                Spacer()
                                Button("Stop", role: .destructive) { stopping = coach }
                                    .buttonStyle(.borderless)
                            }
                        }
                        // FIT-220: the evening "Log today's session?" on a planned day with nothing logged.
                        Toggle(isOn: Binding(get: { nudges }, set: { nudges = $0; Push.nudges = $0 })) {
                            Label("Evening Reminder", systemImage: "bell")
                        }
                    } footer: {
                        Text(failure ?? "Your coach sees your program and training, and can change your program. The reminder comes the evening of a planned day you haven’t logged.")
                            .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                    }
                }
                // FIT-201: someone who started without a coach joins one later, by link or code.
                if pro.coaches.isEmpty, account.isAvailable {
                    Section {
                        Button { joining = true } label: { Label("Join Your Coach", systemImage: "person.2") }
                    }
                }
                // FIT-59: the policy, the terms, and a way to reach us or report a problem (guideline 1.2).
                Section {
                    Link(destination: URL(string: "https://barbrabell.com/support")!) { Label("Help and Report a Problem", systemImage: "questionmark.circle") }
                    Link(destination: URL(string: "https://barbrabell.com/privacy")!) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "https://barbrabell.com/terms")!) { Label("Terms", systemImage: "doc.text") }
                }
                .tint(.primary)
                if let user = account.user {
                    Section {
                        NavigationLink { AccountView() } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(user.name ?? "Account")
                                    if let email = user.email { Text(email).font(.footnote).foregroundStyle(.secondary) }
                                }
                            } icon: { Image(systemName: "person.crop.circle") }
                        }
                    }
                }
            }
            .navigationTitle("You")
            .confirmationDialog("Stop sharing with \(stopping?.mention ?? "your coach")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                                titleVisibility: .visible, presenting: stopping) { coach in
                Button("Stop Sharing", role: .destructive) { stop(coach) }
            } message: { coach in
                Text("\(coach.title) won't see your program or training any more. Your program stays as it is.")
            }
            .sheet(isPresented: $joining) { WelcomeView { joining = false } }
            .sheet(isPresented: $choosing) { ProgramPicker { choosing = false }.tint(RootView.accent) }
            .sheet(isPresented: $signingIn) {
                SignInSheet(reason: "Sign in to back up your program and see it on the web.")
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func stop(_ coach: Cloud.Person) {
        failure = nil
        Task {
            do {
                try await Cloud.unlinkCoach(coach.uid)
                pro.setCoaches(pro.coaches.filter { $0.uid != coach.uid })
            } catch {
                failure = "Couldn't stop sharing. Check your connection and try again."
            }
        }
    }
}
