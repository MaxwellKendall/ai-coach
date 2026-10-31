import SwiftUI
import SwiftData

/// FIT-298: coach mode's first screen (prototype: https://claude.ai/artifact/K9dsMsjX6qxaY6VS3ZrMoC): who needs you,
/// each with the one line that says why, then everyone on track; ＋ invites. A client opens their week.
struct ClientsScreen: View {
    @Environment(Account.self) private var account
    @Environment(Roster.self) private var roster
    @Query private var templates: [Template]
    @State private var inviting = false

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
                        group("Needs you", roster.needsYou)
                        group("On track", roster.onTrack)
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

    @ViewBuilder private func group(_ title: String, _ clients: [Roster.Client]) -> some View {
        if !clients.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(clients) { client in
                        NavigationLink(value: client.id) { ClientRow(client: client) }
                            .buttonStyle(.plain)
                        if client.id != clients.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .cardBackground()
            }
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

/// A client in the list: who, and the one line that says why they need you, or how their week's going.
struct ClientRow: View {
    let client: Roster.Client

    var body: some View {
        HStack(spacing: 12) {
            Text(client.initials).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                .frame(width: 40, height: 40).background(Color.fill, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.headline)
                HStack(spacing: 6) {
                    if let flag = client.week.flags.min(by: { order($0) < order($1) }) {
                        FlagDot(kind: flag.kind)
                        Text(flag.text).lineLimit(1)
                    } else {
                        Text(client.week.planned == 0 ? "Nothing planned this week" : "\(client.week.done) of \(client.week.planned) this week")
                    }
                }
                .font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
        }
        .padding(.vertical, 14)
        .contentShape(.rect)
    }

    private func order(_ flag: Triage.Flag) -> Int { Triage.Flag.Kind.allCases.firstIndex(of: flag.kind)! }
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
        .task {
            do { invite = try await Cloud.createClientInvite() } catch {
                problem = (error as? Cloud.Failure)?.message ?? "Couldn’t make an invite. Try again."
            }
        }
    }
}
