import SwiftUI

/// Everything that isn't today's workout, one tap from Today's header (FIT-27).
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { GoalsScreen() } label: { Label("Goals", systemImage: "target") }
                    NavigationLink { WinsScreen() } label: { Label("Wins", systemImage: "trophy") }
                    NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
                }
                // FIT-52: only once there's an account. Groups (FIT-16) are what ask you to sign in.
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
                #if DEBUG
                // Until FIT-16 adds groups, a debug-only way in to try sign-in.
                if account.user == nil && account.isAvailable {
                    Section { Button("Sign In (debug)") { signingIn = true } }
                }
                #endif
            }
            .sheet(isPresented: $signingIn) { SignInSheet() }
            .navigationTitle("You")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
