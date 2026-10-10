import Foundation
@preconcurrency import Amplify

/// FIT-102: the app's way to Claude: each Messages API request goes to our server (`aiMessages`, the infra's aiProxy
/// Lambda), which holds the key, allows Haiku only, and keeps a daily allowance per signed-in user.
struct ClaudeProxy: ClaudeTransport {
    /// Signed in: the server needs to know who's asking.
    let signedIn: Bool
    var isAvailable: Bool { signedIn }

    func send(_ body: JSON) async throws -> (status: Int, body: JSON) {
        let request = GraphQLRequest<JSON>(
            document: "mutation AiMessages($request: AWSJSON!) { aiMessages(request: $request) }",
            variables: ["request": try ClaudeModel.encoded(body)], responseType: JSON.self, decodePath: "aiMessages")
        switch try await Amplify.API.mutate(request: request) {
        case .success(let reply):
            // AppSync returns AWSJSON as a JSON string.
            let reply = try reply.string.map { try JSONDecoder().decode(JSON.self, from: Data($0.utf8)) } ?? reply
            return (Int(reply["status"]?.number ?? 0), reply["body"] ?? .null)
        case .failure(let error):
            throw ClaudeModel.Failure(description: "Claude through the server: \(error.errorDescription)")
        }
    }
}
