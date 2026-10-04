import SwiftUI

/// FIT-52: Apple first (guideline 4.8), Google second, a hint under the one used last.
/// Shown only when something needs an account; groups (FIT-16) pass their own reason.
struct SignInSheet: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    var reason = "Sign in to share goals with a group."

    @State private var working: Account.Provider?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 12) {
            Text(reason)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
            ForEach(Account.Provider.allCases) { provider in
                VStack(spacing: 6) {
                    button(provider)
                    if provider == account.lastProvider {
                        Text("Last used").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Text("Your workouts stay on this iPhone. Only what you choose to share with a group leaves it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(working != nil)
    }

    @ViewBuilder
    private func button(_ provider: Account.Provider) -> some View {
        let label = HStack {
            if working == provider { ProgressView() } else if provider == .apple { Image(systemName: "apple.logo") }
            Text("Continue with \(provider.title)")
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 34)

        Group {
            if provider == .apple {
                Button { signIn(provider) } label: { label }.buttonStyle(.borderedProminent)
            } else {
                Button { signIn(provider) } label: { label }.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(working != nil)
    }

    private func signIn(_ provider: Account.Provider) {
        working = provider
        failure = nil
        Task {
            defer { working = nil }
            do {
                if try await account.signIn(with: provider) { dismiss() }
            } catch {
                failure = "Couldn't sign in with \(provider.title). Try again."
            }
        }
    }
}
