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
    /// FIT-414: false while the launch splash still covers this screen; the promise rises in once it's lifting.
    var revealed = true
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// The chosen door's title travels into the next screen's title, and back.
    @Namespace private var titles
    /// The promise, its proof and the doors have risen in, once.
    @State private var entered = false
    /// Which lift the example card shows, and whether its target has counted up from the start.
    @State private var example = 0
    @State private var counted = false
    /// An invite code that isn't one shakes the field.
    @State private var shakes = 0

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
    /// FIT-454: Sign In, for an account that already has a program.
    @State private var restoring = false

    var body: some View {
        Group {
            if let coach = askingPush {
                notifications(coach)
            } else if intake {
                IntakeView(onDone: onDone)
            } else if picking {
                // FIT-454: Start My Transformation goes forward into the quiz, as a push would.
                StartFlow(onDone: onDone).motionTransition(.push(from: .trailing))
            } else {
                welcome.motionTransition(.push(from: .trailing))
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
        .animation(.settle, value: account.user)
        .animation(.settle, value: code)
        .animation(.settle, value: door)
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            // What's left gets out of the way at once; what's behind the chosen door rises in under its title, which
            // travels there from the door.
            Group {
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
            }
            .motionTransition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity.animation(.out)))
            Spacer(minLength: 24)
            if door != nil && code == nil {
                Button("Back") { withAnimation(.settle) { door = nil } }
                    .font(.subheadline).foregroundStyle(Color.inkMuted).frame(maxWidth: .infinity).padding(.bottom, 8)
                    .transition(.opacity)
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

    /// `door` names the door this screen opened from, whose title travels up into this one.
    private func title(_ text: String, _ detail: String, from door: Door? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.display(30)).fixedSize(horizontal: false, vertical: true)
                .matchedGeometryEffect(id: door.map { travel($0, "screen") } ?? text, in: titles, properties: .position, anchor: .topLeading)
            // Whole even with the keyboard up for Sign in with email (FIT-229).
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28)
    }

    /// FIT-454 (spec screen 1): the app in a phone, and Start My Transformation. A coach, a coach's client and an
    /// account that already exists each have a quiet way in under it.
    private var doors: some View {
        VStack(spacing: 0) {
            Text("barbrabell").font(.display(22, weight: .heavy)).tracking(-0.3)
                .modifier(Rise(shown: entered, step: 0))
            phone.padding(.top, 18).modifier(Rise(shown: entered, step: 1))
            Button {
                // TKL-466: the funnel's first step after the hero.
                if profiles.first?.programStart == nil { Funnel.track(.started) }
                withAnimation(.settle) { if profiles.first?.programStart == nil { picking = true } else { onDone() } }
            } label: {
                Text("Start My Transformation").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("welcome.own")
            .padding(.top, 24)
            .modifier(Rise(shown: entered, step: 2))
            HStack(spacing: 18) {
                // FIT-382 (author): joining a coach is the quiet way in; most clients come by the coach's invite link,
                // which skips this screen.
                Button { withAnimation(.settle) { door = .athlete } } label: {
                    Text("Have a coach?")
                        .matchedGeometryEffect(id: travel(.athlete, "door"), in: titles, properties: .position, anchor: .topLeading)
                }
                .accessibilityIdentifier("welcome.join")
                Button { withAnimation(.settle) { door = .coach } } label: {
                    Text("I’m a coach")
                        .matchedGeometryEffect(id: travel(.coach, "door"), in: titles, properties: .position, anchor: .topLeading)
                }
                .accessibilityIdentifier("welcome.coach")
                if account.isAvailable, account.user == nil {
                    Button("Sign In") { restoring = true }.accessibilityIdentifier("welcome.signIn")
                }
            }
            .font(.subheadline.weight(.semibold))
            .tint(Color.inkMuted)
            .frame(minHeight: 44)
            .padding(.top, 8)
            .modifier(Rise(shown: entered, step: 3))
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if revealed { entered = true }
            // TKL-466: the funnel's denominator, a first launch; the server counts each install once.
            Funnel.track(.screenViewed, "hero")
        }
        .onChange(of: revealed) { _, now in if now { entered = true } }
        .task(id: entered) { await cycleExamples() }
        .sheet(isPresented: $restoring) { SignInSheet(reason: "Sign in to pick up your program.").presentationDetents([.medium]) }
        // FIT-182: an account's first sync brings a program made elsewhere; with one, there's nothing to set up. Without
        // one, Start My Transformation is still the way in.
        .onChange(of: SyncEngine.shared.lastSynced) { _, synced in
            guard synced != nil, account.user != nil, profiles.first?.programStart != nil else { return }
            onDone()
        }
    }

    /// The app inside a phone: week one's days, and the promise's line rising under the lift.
    private var phone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This week").font(.headline)
            ForEach(Array(["Mon · Full Body A", "Wed · Full Body B", "Fri · Full Body A"].enumerated()), id: \.offset) { index, day in
                HStack {
                    Image(systemName: index == 0 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.inkFaint))
                    Text(day).font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
            exampleCard.padding(.top, 4)
        }
        .padding(18)
        .padding(.top, 14)
        .frame(maxWidth: 290)
        .background(Color.canvas, in: .rect(cornerRadius: 40))
        .overlay { RoundedRectangle(cornerRadius: 40).strokeBorder(Color.ink.opacity(0.85), lineWidth: 6) }
        .overlay(alignment: .top) { Capsule().fill(Color.ink.opacity(0.85)).frame(width: 74, height: 20).padding(.top, 10) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The app, showing this week's sessions and a lift's goal")
    }

    /// The id a door's title and its screen's title share, so one travels into the other; with Reduce Motion on, each
    /// end has its own and the screens only fade.
    private func travel(_ door: Door, _ end: String) -> String { reduceMotion ? "\(door)-\(end)" : "\(door)" }

    /// The promise's proof: a lift's start and the number it reaches, counting up, with a line rising under it. It
    /// moves on to another lift every few seconds, and holds still with Reduce Motion or VoiceOver on.
    private var exampleCard: some View {
        let lift = Self.examples[example]
        return VStack(alignment: .leading, spacing: 4) {
            Text(lift.name).font(.subheadline).foregroundStyle(Color.inkMuted)
                .contentTransition(.opacity)
            HStack(spacing: 0) {
                Text("\(lift.from) → ").contentTransition(.numericText(value: Double(lift.from)))
                Text("\(counted ? lift.to : lift.from)").foregroundStyle(Plate.current.mark)
                    .contentTransition(.numericText(value: Double(counted ? lift.to : lift.from)))
                Text(" lb").foregroundStyle(Plate.current.mark)
            }
            .font(.display(24, weight: .semibold, relativeTo: .title2)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
            .overlay(alignment: .bottomTrailing) {
                RisingLine().trim(from: 0, to: counted ? 1 : 0)
                    .stroke(Plate.current.mark, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 56, height: 10).offset(y: 14)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fill, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("For example, \(lift.name) from \(lift.from) to \(lift.to) pounds")
    }

    static let examples: [(name: String, from: Int, to: Int)] = [("Back Squat", 225, 250), ("Bench Press", 185, 205), ("Deadlift", 315, 345)]

    private func cycleExamples() async {
        guard entered else { return }
        guard !reduceMotion, !voiceOver else { counted = true; return }
        // Counts up once the card has risen in.
        guard await pause(.milliseconds(350)) else { return }
        withAnimation(.reveal) { counted = true }
        while true {
            guard await pause(.seconds(3.5)) else { return }
            withAnimation(.settle) {
                counted = false
                example = (example + 1) % Self.examples.count
            }
            guard await pause(.milliseconds(350)) else { return }
            withAnimation(.reveal) { counted = true }
        }
    }

    /// False once the screen's gone (the task cancelled).
    private func pause(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration); return true } catch { return false }
    }

    /// FIT-296's coach door: sign in, then coach mode (FIT-298); the dashboard keeps import, programs and billing.
    @ViewBuilder private var coachDoor: some View {
        if account.user == nil {
            VStack(alignment: .leading, spacing: 0) {
                title("Take on more clients without working more hours",
                      "Free for any number of clients. Bring the sheets you program in today, and see who needs you first.", from: .coach)
                if account.isAvailable { SignInButtons {} }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                title("Your clients, in your pocket",
                      "See who needs you, reply to their notes, change a session and invite clients, here. Import programs and billing are on barbrabell.com.",
                      from: .coach)
                Button {
                    UserDefaults.standard.set(account.user?.uid, forKey: Roster.coachingKey)
                    onDone()
                } label: {
                    Text("Go to My Clients").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(Plate.current.onAccent).background(.tint, in: .rect(cornerRadius: 18))
                }
                .accessibilityIdentifier("welcome.clients")
                Button("Train on my own too") {
                    UserDefaults.standard.set(account.user?.uid, forKey: Roster.coachingKey)
                    if profiles.first?.programStart == nil { withAnimation(.settle) { picking = true } } else { onDone() }
                }
                .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(code == nil ? "Get stronger with your coach in your pocket" : "Sign in to join your coach",
                  "Your coach writes every session and sees every set you log. Free for you.", from: code == nil ? .athlete : nil)
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
            title("Join your coach", "Open the invite link your coach sent, or type its code.", from: .athlete)
            HStack(spacing: 10) {
                TextField("Invite code", text: $typed)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(Color.fill, in: .capsule)
                    .modifier(Shake(trigger: shakes))
                    .sensoryFeedback(.error, trigger: shakes)
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
                    withAnimation(.settle) { askingPush = nil }
                }
            } label: {
                Text("Turn On Notifications").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            Button("Not Now") { withAnimation(.settle) { askingPush = nil } }
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
            shakes += 1
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
                withAnimation(.settle) {
                    intake = true
                    if ask { askingPush = person.name ?? coach?.name ?? "your coach" }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// FIT-414: one of Welcome's parts rising into place, in order, the first time the screen shows. With Reduce Motion on
/// it fades in where it is.
private struct Rise: ViewModifier {
    let shown: Bool
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(.settle.staggered(step * 2), value: shown)
    }
}

/// The example card's line, rising like the plan reveal's.
private struct RisingLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                      control1: CGPoint(x: rect.width * 0.45, y: rect.maxY),
                      control2: CGPoint(x: rect.width * 0.55, y: rect.minY))
        return path
    }
}
