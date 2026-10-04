import Testing
@testable import AICoach

/// FIT-52: Apple and Google accounts aren't linked, so the provider shown comes from Cognito's username.
struct AccountTests {
    @Test func providerFromCognitoUsername() {
        #expect(Account.Provider(username: "SignInWithApple_001877.3c529019ba09426a8d440765ac5e7e1a.0053") == .apple)
        #expect(Account.Provider(username: "Google_107478565829264097343") == .google)
        #expect(Account.Provider(username: "smoke-a") == nil)
        #expect(Account.Provider(username: "") == nil)
    }

    @Test func appleIsOfferedFirst() {
        // App Store guideline 4.8: Sign in with Apple at least as prominent as other providers.
        #expect(Account.Provider.allCases.first == .apple)
    }
}
