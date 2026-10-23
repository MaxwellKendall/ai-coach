import SwiftUI

/// FIT-201: the pilot's first launch. Sign in, then join your coach: the coach's invite link opens the join step with
/// its code, or the code is typed or pasted. There's no goal or program setup; the coach writes the program. Without a
/// coach the app is a log of your own.
struct WelcomeView: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @Bindable private var navigator = Navigator.shared
    var onDone: () -> Void

    @State private var typed = ""
    /// The invite being answered: the link the app was opened with, or the code typed.
    @State private var code: String?
    /// The invite being answered, once it's looked up; nil when it's used up or expired.
    @State private var coach: Cloud.CoachInvite?
    /// The code `coach` was looked up for.
    @State private var lookedUp: String?
    @State private var working = false
    @State private var failure: String?
    /// FIT-219: joined; the coach's questions follow.
    @State private var intake = false
    /// FIT-220: joined, and notifications not yet allowed or refused: asked first, saying why.
    @State private var askingPush: String?

    var body: some View {
        Group {
            if let coach = askingPush { notifications(coach) } else if intake { IntakeView(onDone: onDone) } else { welcome }
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            if account.user == nil {
                signIn
            } else if let code {
                invite(code)
            } else {
                join
            }
            Spacer(minLength: 24)
            Button(account.user == nil ? "No coach? Log on your own" : "I don’t have a coach") {
                onDone()
            }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            #if DEBUG
            BackendPicker().font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(.systemBackground))
        .animation(.snappy, value: account.user)
        .animation(.snappy, value: code)
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
            Text(text).font(.system(size: 32, weight: .bold)).tracking(-0.4)
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
        .padding(.bottom, 28)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(code == nil ? "Train with your coach" : "Sign in to join your coach",
                  "Your coach writes your program. You follow it here and log each set.")
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
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(working)
                Button("Use a Different Code") { self.code = nil }
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
                    .background(Color(.secondarySystemBackground), in: .capsule)
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
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 16)
        }
    }

    /// FIT-220: why notifications, before the system asks.
    private func notifications(_ coach: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "bell.badge").font(.system(size: 40)).padding(.bottom, 20)
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
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            Button("Not Now") { withAnimation(.snappy) { askingPush = nil } }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(.systemBackground))
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.red).padding(.bottom, 12)
    }

    private func submit() {
        guard let code = InviteLink.coach(typed: typed) else {
            failure = "That isn’t an invite code. It’s the 10 letters and numbers at the end of your coach’s link."
            return
        }
        failure = nil
        self.code = code
    }

    private func lookUp() async {
        guard let code else { return }
        coach = try? await Cloud.coachInvite(code)
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
