import SwiftUI

/// FIT-52: who's signed in, Sign Out, and Delete Account, in the shape of Settings › Apple Account.
struct AccountView: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        List {
            if let user = account.user {
                Section {
                    if let name = user.name { LabeledContent("Name", value: name) }
                    if let email = user.email { LabeledContent("Email", value: email) }
                    if let provider = user.provider { LabeledContent("Signed in with", value: provider.title) }
                }
            }
            Section {
                Button("Sign Out") {
                    Task {
                        await account.signOut()
                        dismiss()
                    }
                }
            }
            Section {
                Button("Delete Account", role: .destructive) { confirmingDelete = true }
                    .disabled(deleting)
            } footer: {
                Text(failure ?? "Removes your account, your group memberships and everything you shared. Workouts on this iPhone stay.")
                    .foregroundStyle(failure == nil ? Color.secondary : Color.red)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if deleting { ProgressView() } }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { delete() }
        } message: {
            Text("This can't be undone. Workouts on this iPhone stay.")
        }
    }

    private func delete() {
        deleting = true
        failure = nil
        Task {
            defer { deleting = false }
            do {
                try await account.deleteAccount()
                dismiss()
            } catch {
                failure = "Couldn't delete your account. Check your connection and try again."
            }
        }
    }
}
