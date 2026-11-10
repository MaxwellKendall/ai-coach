import SwiftUI
import SwiftData

/// FIT-298: coach mode's first screen (prototype: https://claude.ai/artifact/K9dsMsjX6qxaY6VS3ZrMoC): who needs you,
/// each with the one line that says why, then everyone on track; ＋ invites. A client opens their week.
struct ClientsScreen: View {
    @Environment(Account.self) private var account
    @Environment(Roster.self) private var roster
    @Query private var templates: [Template]
    @State private var inviting = false
    @State private var needsOnly = false
    @State private var query = ""

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Clients").font(.display(34))
                        Spacer()
                        Button { inviting = true } label: {
                            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                                .frame(width: 44, height: 44).rowBackground()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Invite a client")
                    }
                    if let problem = roster.problem {
                        Text(problem).font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    if !roster.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if roster.clients.isEmpty {
                        empty
                    } else {
                        if roster.clients.count > 8 { search }
                        if !roster.needsYou.isEmpty {
                            Picker("Show", selection: $needsOnly) {
                                Text("All").tag(false)
                                Text("Needs You (\(roster.needsYou.count))").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        list(shown)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
            .screenBackground()
            .refreshable { await roster.refresh(coach: account.user?.uid, names: names) }
            .task(id: account.user?.uid) { await roster.refresh(coach: account.user?.uid, names: names) }
            .navigationDestination(for: String.self) { id in ClientScreen(id: id) }
            .navigationDestination(for: DayThread.Ref.self) { ref in DayThread(ref: ref) }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $inviting) { InviteSheet() }
        }
    }

    /// FIT-331: everyone A–Z, or only who needs you, narrowed by the search.
    private var shown: [Roster.Client] {
        let clients = needsOnly && !roster.needsYou.isEmpty ? roster.needsYou : roster.clients
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? clients : clients.filter { $0.name.localizedStandardContains(query) }
    }

    /// Search, as in Contacts: a grey field with the magnifying glass.
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.inkMuted)
            TextField("Search", text: $query).autocorrectionDisabled().textInputAutocapitalization(.words)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkFaint) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Color.fill, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private func list(_ clients: [Roster.Client]) -> some View {
        if clients.isEmpty {
            Text("No one called “\(query)”").font(.subheadline).foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity).padding(.top, 24)
        } else {
            VStack(spacing: 0) {
                ForEach(clients) { client in
                    NavigationLink(value: client.id) { ClientRow(client: client) }
                        .buttonStyle(.plain)
                    // Inset to the names' edge, as in Messages.
                    if client.id != clients.last?.id { Divider().padding(.leading, ClientRow.avatar + 12) }
                }
            }
            .padding(.horizontal, 16)
            .cardBackground()
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite your first client").font(.title3.weight(.bold))
            Text("Send them a link. They train in the free app, and you see every set here.")
                .font(.body).foregroundStyle(Color.inkMuted)
            Button { inviting = true } label: { Label("Invite a Client", systemImage: "plus") }
                .buttonStyle(.primary).padding(.top, 12)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// A client in the list, laid out as a Messages row: who, when they last logged, and the one line that says why they
/// need you or how their week's going, with the week as seven dots.
struct ClientRow: View {
    let client: Roster.Client
    static let avatar: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Avatar(client: client, size: Self.avatar)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(client.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let last = client.lastLogged {
                        Text(Self.ago(last)).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    if let flag = client.week.flags.min(by: { order($0) < order($1) }) {
                        FlagDot(kind: flag.kind)
                        Text(flag.text).lineLimit(1)
                    } else {
                        Text(client.week.planned == 0 ? "Nothing planned this week" : "\(client.week.done) of \(client.week.planned) this week")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    WeekDots(units: client.units)
                }
                .font(.subheadline).foregroundStyle(Color.inkMuted)
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private func order(_ flag: Triage.Flag) -> Int { Triage.Flag.Kind.allCases.firstIndex(of: flag.kind)! }

    /// "9:41 AM" today, "Yesterday", the weekday this week, else "Nov 2", as Messages dates its rows.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A client's initials on a soft tint of their own, the same each time (Contacts' monogram, in colour).
struct Avatar: View {
    let client: Roster.Client
    var size: CGFloat = 44

    private static let tints: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .brown]
    /// A stable pick: Swift's hashValue changes between launches.
    private var tint: Color { Self.tints[client.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.tints.count] }

    var body: some View {
        Text(client.initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            .frame(width: size, height: size).background(tint.opacity(0.16), in: .circle)
            .accessibilityHidden(true)
    }
}

/// This week, Sunday to Saturday: filled for a day trained, a ring for one still to come, an amber ring for one planned
/// and missed, and a faint dot for a rest day.
struct WeekDots: View {
    let units: [String: String]

    var body: some View {
        let start = Week.start(of: .now)
        let today = SyncUnits.day(.now)
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { offset in
                let day = SyncUnits.day(Calendar.current.date(byAdding: .day, value: offset, to: start)!)
                Group {
                    if ClientDay.trained(units, day) {
                        Circle().fill(Color.ink)
                    } else if ClientDay.planned(units, day) {
                        Circle().strokeBorder(day < today ? Color(light: 0xa35700, dark: 0xffad42) : Color.inkMuted, lineWidth: 1.5)
                    } else {
                        Circle().fill(Color.inkFaint).padding(2)
                    }
                }
                .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Pain in red, the rest in amber: never colour alone, the flag's words are beside it.
struct FlagDot: View {
    let kind: Triage.Flag.Kind
    var body: some View {
        Circle().fill(kind == .pain ? Color(light: 0xc01b2a, dark: 0xff6b70) : Color(light: 0xa35700, dark: 0xffad42))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// FIT-298: a new client's invite: the code and its link, to share or copy (createClientInvite, FIT-130).
struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var invite: Cloud.ClientInvite?
    @State private var problem: String?
    @State private var copied = false
    /// FIT-228: asked for only when the account has no name, so the invite says who it's from.
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invite a client").font(.title2.weight(.bold))
            Text("They open the link in the free Barbrabell app and say yes to you coaching them.")
                .font(.body).foregroundStyle(Color.inkMuted).padding(.top, 8)
            VStack(spacing: 6) {
                if let invite {
                    Text(invite.code).font(.system(size: 34, weight: .medium, design: .monospaced)).tracking(6)
                        .textSelection(.enabled)
                    Text(invite.url.replacingOccurrences(of: "https://", with: "")).font(.subheadline).foregroundStyle(Color.inkMuted)
                } else if asking {
                    TextField("Your name, as your client will see it", text: $name)
                        .font(.body.weight(.semibold)).multilineTextAlignment(.center)
                        .textContentType(.name).submitLabel(.done)
                        .onSubmit { Task { await make() } }
                } else if let problem {
                    Text(problem).font(.subheadline).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(16)
            .background(Color.fill, in: .rect(cornerRadius: 16))
            .padding(.top, 24)
            if asking {
                Button("Make the Invite") { Task { await make() } }
                    .buttonStyle(.primary).padding(.top, 24)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let invite, let url = URL(string: invite.url) {
                ShareLink(item: url, message: Text("Train with me in Barbrabell. Your code is \(invite.code).")) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary).padding(.top, 24)
                Button(copied ? "Copied" : "Copy Code") {
                    UIPasteboard.general.string = invite.code
                    copied = true
                }
                .buttonStyle(.secondary).padding(.top, 10)
            }
        }
        .padding(.horizontal, 24).padding(.top, 32)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .task { await make() }
    }

    private func make() async {
        let given = name.trimmingCharacters(in: .whitespaces)
        do {
            invite = try await Cloud.createClientInvite(name: asking ? given : nil)
            asking = false
        } catch {
            let message = (error as? Cloud.Failure)?.message
            if message?.contains(Cloud.nameNeeded) == true { asking = true } else { problem = message ?? "Couldn’t make an invite. Try again." }
        }
    }
}
