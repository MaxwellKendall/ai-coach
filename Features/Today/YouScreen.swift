import SwiftUI

/// The account and the library, top right on Today. Program, Progress and Groups are tabs since FIT-64.
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
                    #if DEBUG
                    NavigationLink { VoiceLogView() } label: { Label("Spoken attempts", systemImage: "waveform") }
                    #endif
                    // FIT-122: a year of Pro bought as a gift on the web.
                    if account.isAvailable {
                        NavigationLink { RedeemGiftView() } label: { Label("Redeem a gift", systemImage: "gift") }
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
            .navigationTitle("You")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
