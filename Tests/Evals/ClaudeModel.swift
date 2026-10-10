import Foundation
@testable import AICoach

/// FIT-93: the evals send Claude's requests straight to the Messages API with the key from `.env`; the app goes
/// through our server instead (`ClaudeProxy`). Eval target only.
struct ClaudeAPI: ClaudeTransport {
    let key: String
    /// The app's server refuses a longer request (`limits.maxRequestChars`, infra/lambda/aiProxy.ts), so the evals do too.
    static let proxyLimit = 60_000
    var isAvailable: Bool { !key.isEmpty }

    func send(_ body: JSON) async throws -> (status: Int, body: JSON) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        if let size = request.httpBody?.count, size > Self.proxyLimit {
            throw ClaudeModel.Failure(description: "The request is \(size) characters; the server takes \(Self.proxyLimit).")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null)
    }
}

extension ClaudeModel: MeteredModel {}
