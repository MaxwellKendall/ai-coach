import Foundation
import Observation
@preconcurrency import Amplify
import AWSAPIPlugin
import AWSCognitoAuthPlugin

/// FIT-52: the optional cloud account (Cognito, signed in with Apple or Google).
/// Signed out, the app works exactly as before; only groups (FIT-16) need an account.
@Observable @MainActor
final class Account {
    enum Provider: String, CaseIterable, Identifiable {
        case apple, google

        var id: Self { self }
        var title: String { self == .apple ? "Apple" : "Google" }

        /// Cognito names federated users after their provider, e.g. `SignInWithApple_001877…`, `Google_1074…`.
        init?(username: String) {
            if username.hasPrefix("SignInWithApple_") { self = .apple }
            else if username.hasPrefix("Google_") { self = .google }
            else { return nil }
        }

        fileprivate var amplify: AuthProvider { self == .apple ? .apple : .google }
    }

    struct User: Equatable {
        var name: String?
        var email: String?
        var provider: Provider?
    }

    private(set) var user: User?
    /// False when the backend config is missing or invalid; the app then hides account features.
    let isAvailable: Bool

    /// Decision (FIT-52): Apple and Google accounts aren't linked, so remember which one was used.
    var lastProvider: Provider? {
        get { UserDefaults.standard.string(forKey: "account.lastProvider").flatMap(Provider.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "account.lastProvider") }
    }

    init() {
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSAPIPlugin())
            try Amplify.configure(with: .amplifyOutputs)
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    /// Reads the signed-in user from the keychain-backed session. No network when signed out.
    func refresh() async {
        guard isAvailable, (try? await Amplify.Auth.fetchAuthSession())?.isSignedIn == true,
              let current = try? await Amplify.Auth.getCurrentUser() else {
            user = nil
            return
        }
        let attributes = (try? await Amplify.Auth.fetchUserAttributes()) ?? []
        let value = { (key: AuthUserAttributeKey) in attributes.first { $0.key == key }?.value }
        user = User(name: value(.name), email: value(.email), provider: Provider(username: current.username))
    }

    /// Opens Cognito's hosted sign-in straight at the provider. Returns false if the user cancelled.
    func signIn(with provider: Provider) async throws -> Bool {
        do {
            // A private session skips the "wants to use amazoncognito.com to sign in" alert.
            _ = try await Amplify.Auth.signInWithWebUI(
                for: provider.amplify,
                presentationAnchor: nil,
                options: .preferPrivateSession()
            )
        } catch let error as AuthError {
            if case .service(_, _, let underlying) = error, case .userCancelled? = underlying as? AWSCognitoAuthError {
                return false
            }
            throw error
        }
        lastProvider = provider
        await refresh()
        return true
    }

    func signOut() async {
        _ = await Amplify.Auth.signOut()
        user = nil
    }

    /// App Store 5.1.1(v): removes the account and everything it shared (FIT-56 `deleteAccount`).
    /// Workouts on this iPhone are untouched; they were never uploaded.
    func deleteAccount() async throws {
        let request = GraphQLRequest<Bool>(document: "mutation { deleteAccount }", responseType: Bool.self, decodePath: "deleteAccount")
        if case .failure(let error) = try await Amplify.API.mutate(request: request) {
            throw error
        }
        // The server already deleted the Cognito user, so only clear the local session.
        _ = await Amplify.Auth.signOut(options: .init(globalSignOut: false))
        user = nil
    }
}
