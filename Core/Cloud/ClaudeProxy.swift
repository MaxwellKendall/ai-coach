import Foundation
import StoreKit
@preconcurrency import Amplify

/// FIT-102: the app's way to Claude: each Messages API request goes to our server (`aiMessages`, the infra's aiProxy
/// Lambda), which holds the key, allows Haiku only, and keeps a daily allowance per signed-in user. FIT-123: each
/// request carries the Pro transaction as Apple signed it, which the server checks; without one, an account has a few.
struct ClaudeProxy: ClaudeTransport {
    /// Signed in: the server needs to know who's asking.
    let signedIn: Bool
    var isAvailable: Bool { signedIn }

    func send(_ body: JSON) async throws -> (status: Int, body: JSON) {
        var variables: [String: Any] = ["request": try ClaudeModel.encoded(body)]
        if let entitlement = await Self.entitlement() { variables["entitlement"] = entitlement }
        let request = GraphQLRequest<JSON>(
            document: "mutation AiMessages($request: AWSJSON!, $entitlement: String) { aiMessages(request: $request, entitlement: $entitlement) }",
            variables: variables, responseType: JSON.self, decodePath: "aiMessages")
        switch try await Amplify.API.mutate(request: request) {
        case .success(let reply):
            // AppSync returns AWSJSON as a JSON string.
            let reply = try reply.string.map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) } ?? reply
            return (Int(reply["status"]?.number ?? 0), reply["body"] ?? .null)
        case .failure(let error):
            throw ClaudeModel.Failure(description: "Claude through the server: \(error.errorDescription)")
        }
    }

    /// The current Pro subscription's signed transaction, as StoreKit holds it.
    static func entitlement() async -> String? {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Pro.products.contains(transaction.productID) {
                return result.jwsRepresentation
            }
        }
        return nil
    }
}
