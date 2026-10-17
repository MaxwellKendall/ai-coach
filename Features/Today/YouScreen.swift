import SwiftUI

/// The account and the library, top right on Today. Program, Progress and Groups are tabs since FIT-64.
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @State private var signingIn = false
    @State private var stopping: Cloud.Person?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
                    // FIT-122: a year of Pro bought as a gift on the web.
                    if account.isAvailable {
                        NavigationLink { RedeemGiftView() } label: { Label("Redeem a gift", systemImage: "gift") }
                    }
                }
                // FIT-126: signed out, a way in: the account keeps the program backed up and on the web.
                if account.user == nil, account.isAvailable {
                    Section {
                        Button { signingIn = true } label: {
                            Label("Sign In", systemImage: "person.crop.circle")
                        }
                    } footer: {
                        Text("Back up your program and see it on the web.")
                    }
                }
                // FIT-130: who coaches me, and the way to stop.
                if account.user != nil, !pro.coaches.isEmpty {
                    Section {
                        ForEach(pro.coaches) { coach in
                            HStack {
                                Label("Coached by \(coach.title)", systemImage: "person.2")
                                Spacer()
                                Button("Stop", role: .destructive) { stopping = coach }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } footer: {
                        Text(failure ?? "Your coach sees your program and training, and can change your program.")
                            .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                    }
                }
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
            .confirmationDialog("Stop sharing with \(stopping?.title ?? "your coach")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                                titleVisibility: .visible, presenting: stopping) { coach in
                Button("Stop Sharing", role: .destructive) { stop(coach) }
            } message: { coach in
                Text("\(coach.title) won't see your program or training any more. Your program stays as it is.")
            }
            .sheet(isPresented: $signingIn) {
                SignInSheet(reason: "Sign in to back up your program and see it on the web.")
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func stop(_ coach: Cloud.Person) {
        failure = nil
        Task {
            do {
                try await Cloud.unlinkCoach(coach.uid)
                pro.setCoaches(pro.coaches.filter { $0.uid != coach.uid })
            } catch {
                failure = "Couldn't stop sharing. Check your connection and try again."
            }
        }
    }
}
