import AuthenticationServices
import CryptoKit
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

        /// Cognito names federated users after their provider, e.g. `SignInWithApple_001877…`, `Google_1074…`;
        /// native Apple users (FIT-138) are `apple_001877…`.
        init?(username: String) {
            if username.hasPrefix("SignInWithApple_") || username.hasPrefix("apple_") { self = .apple }
            else if username.hasPrefix("Google_") { self = .google }
            else { return nil }
        }

        fileprivate var amplify: AuthProvider { self == .apple ? .apple : .google }
    }

    struct User: Equatable {
        /// Cognito's `sub`: the uid on every group item.
        var uid: String
        var name: String?
        var email: String?
        var provider: Provider?
    }

    private(set) var user: User?
    /// FIT-57: Release (TestFlight and the App Store) talks to AICoach-prod and bundles only its file; Debug
    /// bundles both and talks to the one `Backend.current` names.
    static let outputs = "amplify_outputs.\(Backend.current.rawValue)"

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
            try Amplify.configure(with: .resource(named: Self.outputs))
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
        user = User(uid: current.userId, name: value(.name), email: value(.email), provider: Provider(username: current.username))
    }

    /// FIT-138: Sign in with Apple's own sheet (one tap, Face ID), no web page. The app asks Apple with the hash of a
    /// fresh nonce and keeps the nonce; `appleStart` checks Apple's token and names the Cognito user (creating it the
    /// first time), then Cognito's custom auth signs that user in with the same token, so Amplify keeps the session.
    final class AppleRequest {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()

        func prepare(_ request: ASAuthorizationAppleIDRequest) {
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum AppleSignInError: Error { case noToken, refused, unexpectedStep }

    func signIn(apple credential: ASAuthorizationAppleIDCredential, nonce: String) async throws {
        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else { throw AppleSignInError.noToken }
        // Apple shares the name only the first time; appleStart keeps it for a new account.
        let name = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        let username = try await appleUsername(token: token, nonce: nonce, name: name?.isEmpty == false ? name : nil)
        let options = AuthSignInRequest.Options(pluginOptions: AWSAuthSignInOptions(authFlowType: .customWithoutSRP))
        let start = try await Amplify.Auth.signIn(username: username, options: options)
        guard case .confirmSignInWithCustomChallenge = start.nextStep else { throw AppleSignInError.unexpectedStep }
        let answer = String(decoding: try JSONEncoder().encode(["identityToken": token, "nonce": nonce]), as: UTF8.self)
        let done = try await Amplify.Auth.confirmSignIn(challengeResponse: answer)
        guard done.isSignedIn else { throw AppleSignInError.refused }
        lastProvider = .apple
        await refresh()
    }

    private func appleUsername(token: String, nonce: String, name: String?) async throws -> String {
        guard let url = Self.appleStartURL else { throw AppleSignInError.refused }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["identityToken": token, "nonce": nonce, "name": name])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppleSignInError.refused }
        guard let username = try JSONDecoder().decode([String: String].self, from: data)["username"] else { throw AppleSignInError.refused }
        return username
    }

    /// The `appleStart` function URL, written into amplify_outputs' `custom` section by infra/scripts/outputs.ts.
    /// Missing (a backend not yet deployed with FIT-138), Apple signs in through the hosted UI as before.
    static let appleStartURL: URL? = {
        struct Outputs: Decodable { struct Custom: Decodable { let apple_start_url: URL }; let custom: Custom }
        guard let file = Bundle.main.url(forResource: outputs, withExtension: "json"), let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode(Outputs.self, from: data))?.custom.apple_start_url
    }()

    var hasNativeApple: Bool { isAvailable && Self.appleStartURL != nil }

    /// Cognito's hosted sign-in straight at the provider: Google, or Apple without `appleStart`. Returns false if the user cancelled.
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

    enum PasswordSignInError: Error { case notSignedIn }

    /// FIT-229: email and password, for the accounts we make with admin rights (App Review's). There's no sign-up:
    /// preSignUp refuses it, so this only signs in.
    func signIn(email: String, password: String) async throws {
        let result = try await Amplify.Auth.signIn(username: email.trimmingCharacters(in: .whitespaces).lowercased(), password: password)
        guard result.isSignedIn else { throw PasswordSignInError.notSignedIn }
        await refresh()
    }

    func signOut() async {
        _ = await Amplify.Auth.signOut()
        user = nil
    }

    /// App Store 5.1.1(v): removes the account and everything it shared (FIT-56 `deleteAccount`).
    /// Workouts on this iPhone are untouched; the server copy of them (FIT-126) goes with the account.
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
