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
    @State private var messaging = false
    @State private var query = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let problem = roster.problem {
                        Text(problem).font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    if !roster.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if roster.clients.isEmpty {
                        empty
                    } else {
                        if !roster.needsYou.isEmpty {
                            Picker("Show", selection: $needsOnly) {
                                Text("All").tag(false)
                                Text("Needs You (\(roster.needsYou.count))").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        list(shown)
                    }
                    if !roster.invites.isEmpty, query.isEmpty { invited }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
            }
            .screenBackground()
            // FIT-367: a native large title that goes inline over the list as it scrolls, its buttons in the toolbar,
            // and the system's search under the title once the list is long (FIT-331).
            .navigationTitle("Clients")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // FIT-340: one message to several clients.
                    if roster.clients.count > 1 {
                        Button { messaging = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("Message clients")
                    }
                    Button { inviting = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Invite a client")
                }
            }
            .modifier(Searching(on: roster.clients.count > 8, query: $query))
            .refreshable { await reload() }
            .task(id: "\(account.restored) \(account.user?.uid ?? "")") { await reload() }
            .navigationDestination(for: String.self) { id in ClientScreen(id: id) }
            .navigationDestination(for: DayThread.Ref.self) { ref in DayThread(ref: ref) }
            .navigationDestination(for: ClientProgressScreen.Ref.self) { ref in ClientProgressScreen(id: ref.client) }
            .navigationDestination(for: ClientScreen.Opening.self) { opening in ClientScreen(id: opening.client, day: opening.day) }
            // FIT-338: a coach's notification opens that client on that day.
            .onChange(of: Navigator.shared.clientDay, initial: true) { _, target in
                guard let target, let client = target.client else { return }
                Navigator.shared.clientDay = nil
                path = NavigationPath()
                path.append(ClientScreen.Opening(client: client, day: target.day.map { SyncUnits.day($0) }))
                Task { await reload() }
            }
            .sheet(isPresented: $inviting) { InviteSheet() }
            .sheet(isPresented: $messaging) { MessageClientsSheet() }
        }
    }

    /// FIT-331: everyone A–Z, or only who needs you, narrowed by the search.
    private var shown: [Roster.Client] {
        let clients = needsOnly && !roster.needsYou.isEmpty ? roster.needsYou : roster.clients
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? clients : clients.filter { $0.name.localizedStandardContains(query) }
    }

    /// FIT-339: invites not used yet: when each was sent, to share again or take back.
    private var invited: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Invited").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(roster.invites, id: \.code) { invite in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope").foregroundStyle(Color.inkMuted).frame(width: ClientRow.avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            // FIT-360: who it's for, when the coach said; else its code.
                            if let client = invite.client {
                                Text(client).font(.headline)
                                Text("\(invite.code) · \(Self.sent(invite.createdAt).lowercased())").font(.subheadline).foregroundStyle(Color.inkMuted)
                            } else {
                                Text(invite.code).font(.headline.monospaced())
                                Text(Self.sent(invite.createdAt)).font(.subheadline).foregroundStyle(Color.inkMuted)
                            }
                        }
                        Spacer()
                        if let url = URL(string: invite.url) {
                            ShareLink(item: url, message: Text("Train with me in Barbrabell. Your code is \(invite.code).")) {
                                Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                            }
                            .accessibilityLabel("Share invite \(invite.code)")
                        }
                        Menu {
                            Button("Cancel Invite", systemImage: "xmark", role: .destructive) {
                                Task { try? await roster.cancel(invite.code) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Color.inkMuted).frame(width: 32, height: 44)
                        }
                    }
                    .padding(.vertical, 8)
                    if invite.code != roster.invites.last?.code { Divider().padding(.leading, ClientRow.avatar + 12) }
                }
            }
            .padding(.horizontal, 16)
            .cardBackground()
        }
    }

    /// "Sent today", "Sent yesterday", "Sent Nov 2".
    static func sent(_ at: String?) -> String {
        guard let at, let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(at)
                ?? Date.ISO8601FormatStyle().parse(at) else { return "Not joined yet" }
        if Calendar.current.isDateInToday(date) { return "Sent today" }
        if Calendar.current.isDateInYesterday(date) { return "Sent yesterday" }
        return "Sent \(date.formatted(.dateTime.month(.abbreviated).day()))"
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
                    if client.id != clients.last?.id { Divider().padding(.leading, typeSize.isAccessibilitySize ? 0 : ClientRow.avatar + 12) }
                }
            }
            .padding(.horizontal, 16)
            .cardBackground()
        }
    }

    /// Not before the account has read its session: at launch there's no user yet, which isn't signed out, and the
    /// saved list stays up meanwhile.
    private func reload() async {
        if account.restored { await roster.refresh(coach: account.user?.uid, names: names) }
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

/// The system's search, only for a list long enough to need it.
private struct Searching: ViewModifier {
    var on: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if on { content.searchable(text: $query, prompt: "Search") } else { content }
    }
}

/// A client in the list, laid out as a Messages row: who, when they last logged, and the one line that says why they
/// need you or how their week's going, with the week as seven dots.
struct ClientRow: View {
    @Environment(Roster.self) private var roster
    let client: Roster.Client
    static let avatar: CGFloat = 44

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            // FIT-367: accessibility sizes give the words the row's width: no monogram, and each part on its own line.
            if !typeSize.isAccessibilitySize {
                Avatar(client: client, size: Self.avatar)
                    // FIT-338: something new from them, as Messages marks an unread conversation.
                    .overlay(alignment: .topTrailing) {
                        if roster.unread(client) > 0 { unread }
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if roster.unread(client) > 0 { unread }
                        Text(client.name).font(.headline)
                    }
                    status.font(.subheadline).foregroundStyle(Color.inkMuted)
                    HStack {
                        if let last = client.lastLogged { Text(Self.ago(last)) }
                        Spacer(minLength: 8)
                        WeekDots(units: client.units)
                    }
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(client.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        if let last = client.lastLogged {
                            Text(Self.ago(last)).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
                        }
                    }
                    HStack(spacing: 6) {
                        status.lineLimit(1)
                        Spacer(minLength: 8)
                        WeekDots(units: client.units)
                    }
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private var unread: some View {
        Circle().fill(Plate.current.mark).frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.surface, lineWidth: 2))
            .accessibilityLabel("Unread")
    }

    /// The one line that says why they need you, or how their week's going.
    @ViewBuilder private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let flag = client.week.flags.min(by: { order($0) < order($1) }) {
                FlagDot(kind: flag.kind)
                Text(flag.text)
            } else {
                Text(client.week.planned == 0 ? "Nothing planned this week" : "\(client.week.done) of \(client.week.planned) this week")
            }
        }
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
        Text(client.initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(tint) // ui-score: allow dynamic-type: glyph sized to its fixed frame
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
                        Circle().strokeBorder(day < today ? Color.warn : Color.inkMuted, lineWidth: 1.5)
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
        Circle().fill(kind == .pain ? Color.pain : Color.warn)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// FIT-298: a new client's invite: the code and its link, to share or copy (createClientInvite, FIT-130).
struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var invite: Cloud.ClientInvite?
    @State private var problem: String?
    @State private var copied = false
    /// FIT-228: asked for only when the account has no name, so the invite says who it's from.
    @State private var asking = false
    @State private var name = ""
    /// FIT-360: who it's for, asked first (optional), so open invites can be told apart.
    @State private var client = ""
    @State private var making = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invite a client").font(.title2.weight(.bold))
            Text("They open the link in the free Barbrabell app and say yes to you coaching them.")
                .font(.body).foregroundStyle(Color.inkMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            // FIT-367: a name is typed in an ordinary field; the big box is for the code once it's made.
            if invite == nil, problem == nil, !making {
                Group {
                    if asking {
                        TextField("Your name, as your client will see it", text: $name)
                    } else {
                        TextField("Who’s it for? (optional)", text: $client)
                    }
                }
                .textContentType(.name).submitLabel(.done)
                .onSubmit { Task { await make() } }
                .padding(.horizontal, 16).frame(minHeight: 50)
                // fillStrong: plain fill barely shows on a dark sheet.
                .background(Color.fillStrong, in: .rect(cornerRadius: 12))
                .padding(.top, 24)
            } else {
                VStack(spacing: 6) {
                    if let invite {
                        Text(invite.code).font(.display(34, weight: .medium, design: .monospaced)).tracking(6)
                            .textSelection(.enabled)
                        Text(invite.url.replacingOccurrences(of: "https://", with: "")).font(.subheadline).foregroundStyle(Color.inkMuted)
                    } else if let problem {
                        Text(problem).font(.subheadline).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .padding(16)
                .background(Color.fill, in: .rect(cornerRadius: 18))
                .padding(.top, 24)
            }
            if asking {
                Button("Make the Invite") { Task { await make() } }
                    .buttonStyle(.primary).padding(.top, 24)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if invite == nil, problem == nil, !making {
                Button("Make the Invite") { Task { await make() } }.buttonStyle(.primary).padding(.top, 24)
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
        // FIT-367: accessibility sizes need the whole height, or the explanation is cut off.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium])
        .presentationBackground(Color(.systemBackground))
    }

    private func make() async {
        let given = name.trimmingCharacters(in: .whitespaces)
        making = true
        defer { making = false }
        do {
            invite = try await Cloud.createClientInvite(name: asking ? given : nil, client: client.trimmingCharacters(in: .whitespaces))
            asking = false
        } catch {
            let message = (error as? Cloud.Failure)?.message
            if message?.contains(Cloud.nameNeeded) == true { asking = true } else { problem = message ?? "Couldn’t make an invite. Try again." }
        }
    }
}
