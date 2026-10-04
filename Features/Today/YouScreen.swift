import SwiftUI

/// Everything that isn't today's workout, one tap from Today's header (FIT-27).
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @State private var goals = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { goals = true } label: { Label("Goals", systemImage: "target").foregroundStyle(.primary) }
                    NavigationLink { WinsScreen() } label: { Label("Wins", systemImage: "trophy") }
                    NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
                }
                // FIT-16: groups are what ask you to sign in, so they're the way in to an account.
                if account.isAvailable {
                    Section {
                        NavigationLink { GroupsScreen() } label: { Label("Groups", systemImage: "person.2") }
                    }
                }
                // FIT-52: only once there's an account.
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
            .sheet(isPresented: $goals) { ProgramScreen(tab: .goals) }
            .navigationTitle("You")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
