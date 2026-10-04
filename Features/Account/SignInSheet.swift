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

    private func button(_ provider: Account.Provider) -> some View {
        Button { signIn(provider) } label: {
            HStack(spacing: 12) {
                if working == provider {
                    ProgressView()
                } else if provider == .apple {
                    Image(systemName: "apple.logo").font(.title3)
                } else {
                    Image("GoogleG").resizable().frame(width: 20, height: 20)
                }
                Text("Continue with \(provider.title)")
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(BrandButtonStyle(provider: provider))
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

/// Each provider's own button rules, not the app's tint.
/// Apple HIG "Sign in with Apple": black in light mode, white in dark mode.
/// Google sign-in branding guidelines: light theme #FFFFFF with a 1px #747775 stroke, dark theme #131314
/// with #8E918F, the standard colour "G", 16 pt padding on iOS. SF stands in for Google Sans, which isn't licensed for apps.
private struct BrandButtonStyle: ButtonStyle {
    let provider: Account.Provider
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let (fill, text, stroke): (Color, Color, Color?) = switch provider {
        case .apple: dark ? (.white, .black, nil) : (.black, .white, nil)
        case .google: dark
            ? (Color(hex: 0x131314), Color(hex: 0xE3E3E3), Color(hex: 0x8E918F))
            : (.white, Color(hex: 0x1F1F1F), Color(hex: 0x747775))
        }
        return configuration.label
            .foregroundStyle(text)
            .background(fill, in: .capsule)
            .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 1) } }
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.6)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
