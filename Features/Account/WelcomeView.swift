import SwiftUI
import SwiftData

/// FIT-296: the first launch, three doors under one promise: train on your own (the quiz, FIT-230), with a coach (sign
/// in, then the invite link or code, FIT-201), or as a coach (sign in, then coach mode, FIT-298).
/// Prototype: https://claude.ai/artifact/TbcJ19r3c4r77p38BERgMw
struct WelcomeView: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @Bindable private var navigator = Navigator.shared
    @Query private var profiles: [Profile]
    var onDone: () -> Void

    @State private var typed = ""
    /// The invite being answered: the link the app was opened with, or the code typed.
    @State private var code: String?
    /// The invite being answered, once it's looked up; nil when it's used up or expired.
    @State private var coach: Cloud.CoachInvite?
    /// The code `coach` was looked up for.
    @State private var lookedUp: String?
    /// FIT-380: the lookup didn't reach the server, which isn't the same as a used code.
    @State private var unreachable = false
    @State private var working = false
    @State private var failure: String?
    /// FIT-219: joined; the coach's questions follow.
    @State private var intake = false
    /// FIT-220: joined, and notifications not yet allowed or refused: asked first, saying why.
    @State private var askingPush: String?
    /// FIT-230: no coach, and no program yet: pick one.
    @State private var picking = false
    /// FIT-296: the door picked on the first screen; an invite link skips it.
    @State private var door: Door?
    enum Door { case athlete, coach }

    var body: some View {
        Group {
            if let coach = askingPush {
                notifications(coach)
            } else if intake {
                IntakeView(onDone: onDone)
            } else if picking {
                ProgramPicker(onDone: onDone)
            } else {
                welcome
            }
        }
        #if DEBUG
            // `-intake YES` opens the coach's questions on a fresh simulator, without signing in or an invite;
            // `-askPush Sam` the notifications ask before them.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "intake") { intake = true }
                if let coach = UserDefaults.standard.string(forKey: "askPush") { intake = true; askingPush = coach }
            }
        #endif
    }

    /// Scrolls when large text needs more than the screen (FIT-364); fills it, centred, otherwise.
    private var welcome: some View {
        GeometryReader { proxy in
            ScrollView { welcomeContent.frame(minHeight: proxy.size.height) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .screenBackground()
        .animation(.snappy, value: account.user)
        .animation(.snappy, value: code)
        .animation(.snappy, value: door)
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            if door == nil && code == nil {
                doors
            } else if door == .coach {
                coachDoor
            } else if account.user == nil {
                signIn
            } else if let code {
                invite(code)
            } else {
                join
            }
            Spacer(minLength: 24)
            if door != nil && code == nil {
                Button("Back") { withAnimation(.snappy) { door = nil } }
                    .font(.subheadline).foregroundStyle(Color.inkMuted).frame(maxWidth: .infinity).padding(.bottom, 8)
            }
            #if DEBUG
            BackendPicker().font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        // Taken from the navigator, so the app's own invite sheet doesn't answer it too.
        .onChange(of: navigator.coachInvite, initial: true) { _, link in
            guard let link else { return }
            code = link
            navigator.coachInvite = nil
        }
        // Signed in to an account that already has a coach (another phone, or joined on the web): nothing to ask.
        .task(id: account.user?.uid) {
            guard account.user != nil else { return }
            await pro.refreshCoaches(signedIn: true)
            if code == nil, !pro.coaches.isEmpty { onDone() }
        }
        .task(id: account.user == nil ? nil : code) { await lookUp() }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.display(30)).fixedSize(horizontal: false, vertical: true)
            // Whole even with the keyboard up for Sign in with email (FIT-229).
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28)
    }

    /// The promise, its proof, the two doors, each by its outcome, and the way in for a coach's client.
    private var doors: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hit your number by the date you set.").font(.display(34))
                .fixedSize(horizontal: false, vertical: true)
            Text("A free plan from your own lifts, that moves when life does.").font(.body).foregroundStyle(Color.inkMuted)
                .padding(.top, 10)
            HStack(alignment: .firstTextBaseline) {
                Text("Back Squat").font(.subheadline).foregroundStyle(Color.inkMuted)
                Spacer()
                Text("225 → \(Text("250 lb").foregroundStyle(Plate.current.mark))").font(.display(24, weight: .semibold, relativeTo: .title2))
            }
            .padding(16).background(Color.fill, in: .rect(cornerRadius: 18)).padding(.top, 22)
            .accessibilityLabel("For example, Back Squat from 225 to 250 pounds")
            VStack(spacing: 10) {
                doorButton("Train on my own", "Your number, by your date", primary: true) {
                    if profiles.first?.programStart == nil { withAnimation(.snappy) { picking = true } } else { onDone() }
                }
                doorButton("I’m a coach", "More clients, not more hours") { door = .coach }
            }
            .padding(.top, 28)
            // FIT-382 (author): joining a coach is the quiet way in, a link under the doors; most clients come by the
            // coach's invite link, which skips this screen.
            Button { withAnimation(.snappy) { door = .athlete } } label: {
                Text("Have a coach? \(Text("Join them").foregroundStyle(Plate.current.mark).fontWeight(.semibold))")
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    private func doorButton(_ title: String, _ detail: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).opacity(primary ? 0.85 : 1)
                        .foregroundStyle(primary ? AnyShapeStyle(Plate.current.onAccent) : AnyShapeStyle(Color.inkMuted))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.7)
            }
            .foregroundStyle(primary ? AnyShapeStyle(Plate.current.onAccent) : AnyShapeStyle(Color.ink))
            .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 66)
            .background(primary ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.fill), in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// FIT-296's coach door: sign in, then coach mode (FIT-298); the dashboard keeps import, programs and billing.
    @ViewBuilder private var coachDoor: some View {
        if account.user == nil {
            VStack(alignment: .leading, spacing: 0) {
                title("Take on more clients without working more hours",
                      "Free for any number of clients. Bring the sheets you program in today, and see who needs you first.")
                if account.isAvailable { SignInButtons {} }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                title("Your clients, in your pocket",
                      "See who needs you, reply to their notes, change a session and invite clients, here. Import programs and billing are on barbrabell.com.")
                Button {
                    UserDefaults.standard.set(account.user?.uid, forKey: Roster.coachingKey)
                    onDone()
                } label: {
                    Text("Go to My Clients").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(Plate.current.onAccent).background(.tint, in: .rect(cornerRadius: 18))
                }
                Button("Train on my own too") {
                    UserDefaults.standard.set(account.user?.uid, forKey: Roster.coachingKey)
                    if profiles.first?.programStart == nil { withAnimation(.snappy) { picking = true } } else { onDone() }
                }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(code == nil ? "Get stronger with your coach in your pocket" : "Sign in to join your coach",
                  "Your coach writes every session and sees every set you log. Free for you.")
            if account.isAvailable { SignInButtons {} }
        }
    }

    @ViewBuilder private func invite(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if lookedUp != code {
                ProgressView().frame(maxWidth: .infinity)
            } else if let coach {
                title(coach.name.map { "Let \($0) coach you?" } ?? "A coach invited you",
                      "\(coach.name ?? "Your coach") will see your program and how your sessions go, and can change your program. You can stop any time on You.")
                if let failure { problem(failure) }
                Button { accept(code) } label: {
                    Group { if working { ProgressView() } else { Text("Allow") } }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.primary)
                .disabled(working)
                Button("Use a Different Code") { self.code = nil }
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
            } else if unreachable {
                title("Couldn’t check this invite", "You may be offline. Try again once you’re connected.")
                Button {
                    lookedUp = nil
                    Task { await lookUp() }
                } label: { Text("Try Again").font(.headline).frame(maxWidth: .infinity, minHeight: 54) }
                    .buttonStyle(.primary)
                Button("Type a Code") { self.code = nil }
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
            } else {
                title("This invite has been used or has expired", "Ask your coach for a new link.")
                Button("Type a Code") { self.code = nil }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var join: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Join your coach", "Open the invite link your coach sent, or type its code.")
            HStack(spacing: 10) {
                TextField("Invite code", text: $typed)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(Color.fill, in: .capsule)
                    .onSubmit(submit)
                // Apple's paste button reads the clipboard only when tapped, so there's no permission prompt.
                PasteButton(payloadType: String.self) { pasted in
                    Task { @MainActor in
                        typed = pasted.first ?? ""
                        submit()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(.primary)
            }
            if let failure { problem(failure).padding(.top, 10) }
            Button { submit() } label: {
                Text("Join").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 16)
        }
    }

    /// FIT-220: why notifications, before the system asks.
    private func notifications(_ coach: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "bell.badge").font(.display(40, weight: .regular)).padding(.bottom, 20)
            title("Hear from \(coach)",
                  "A notification when \(coach) changes your week or replies to a session, and a reminder in the evening of a day you haven’t logged. Turn the reminder off any time on You.")
            Spacer(minLength: 24)
            Button {
                Task {
                    await Push.request()
                    withAnimation(.snappy) { askingPush = nil }
                }
            } label: {
                Text("Turn On Notifications").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            Button("Not Now") { withAnimation(.snappy) { askingPush = nil } }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .screenBackground()
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.red).padding(.bottom, 12)
    }

    private func submit() {
        guard let code = InviteLink.coach(typed: typed) else {
            failure = "That isn’t an invite code. It’s the 6 letters and numbers your coach sent, also at the end of their link."
            return
        }
        failure = nil
        self.code = code
    }

    private func lookUp() async {
        guard let code else { return }
        // The server answers nil for a used or expired code; a throw is the network or the server.
        do {
            coach = try await Cloud.coachInvite(code)
            unreachable = false
        } catch {
            coach = nil
            unreachable = true
        }
        lookedUp = code
    }

    private func accept(_ code: String) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let person = try await Cloud.acceptCoach(code)
                pro.setCoaches(pro.coaches.filter { $0.uid != person.uid } + [person])
                let ask = await Push.undecided()
                withAnimation(.snappy) {
                    intake = true
                    if ask { askingPush = person.name ?? coach?.name ?? "your coach" }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
