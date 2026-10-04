import SwiftUI
import SwiftData

/// FIT-16: your groups, one tap from You. Signed out or with no groups it's an empty state with the two ways in;
/// either asks you to sign in first (sign-in is only ever asked for here, FIT-52).
struct GroupsScreen: View {
    @Environment(Account.self) private var account
    @State private var groups: [Cloud.GroupSummary]?
    @State private var sheet: Sheet?
    /// What to open once sign-in finishes.
    @State private var afterSignIn: Sheet?
    @State private var signingIn = false
    @State private var opened: Cloud.GroupSummary?
    @State private var failure: String?

    enum Sheet: String, Identifiable {
        case create, join
        var id: String { rawValue }
    }

    var body: some View {
        content
            .navigationTitle("Groups")
            .toolbar {
                if account.user != nil, groups?.isEmpty == false {
                    Menu {
                        Button("New Group", systemImage: "plus") { open(.create) }
                        Button("Join with Code", systemImage: "number") { open(.join) }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Group")
                }
            }
            .task(id: account.user?.uid) { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $signingIn, onDismiss: {
                if account.user != nil { sheet = afterSignIn }
                afterSignIn = nil
            }) {
                SignInSheet(reason: afterSignIn == .join ? "Sign in to join the group." : "Sign in to start a group.")
            }
            .sheet(item: $sheet) { sheet in
                NavigationStack {
                    switch sheet {
                    case .create: NewGroupSheet { created($0) }
                    case .join: JoinGroupSheet { created($0) }
                    }
                }
            }
            .navigationDestination(item: $opened) { GroupScreen(summary: $0) }
    }

    @ViewBuilder private var content: some View {
        if account.user != nil, let groups, !groups.isEmpty {
            List(groups) { group in
                NavigationLink(value: group) {
                    Label(group.name, systemImage: "person.2")
                }
            }
            .navigationDestination(for: Cloud.GroupSummary.self) { GroupScreen(summary: $0) }
        } else if account.user != nil, groups == nil, failure == nil {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("Train Together", systemImage: "person.2")
            } description: {
                Text(failure ?? "Share a goal with family or friends and see each other's progress. Only your progress is shared, plus your workouts live if you turn that on.")
            } actions: {
                Button("New Group") { open(.create) }
                    .buttonStyle(.borderedProminent)
                Button("Join with Code") { open(.join) }
            }
        }
    }

    private func open(_ next: Sheet) {
        if account.user == nil {
            afterSignIn = next
            signingIn = true
        } else {
            sheet = next
        }
    }

    private func created(_ group: Cloud.GroupSummary) {
        sheet = nil
        if !(groups ?? []).contains(group) { groups = (groups ?? []) + [group] }
        opened = group
        // FIT-59: notifications are asked for here, when they start to mean something.
        Task { await Push.request() }
    }

    private func load() async {
        guard account.user != nil else { groups = nil; return }
        do {
            groups = try await Cloud.myGroups()
            failure = nil
        } catch {
            failure = "Couldn't load your groups. Pull to try again."
        }
    }
}
