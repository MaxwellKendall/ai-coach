import FoundationModels

/// FIT-102: a model that falls back to another when its call fails: Claude through our server, then the on-device
/// model when there's no network, the daily allowance is used up, or the server can't answer. A session that falls
/// back starts over on the fallback with the same instructions and prompt; the app's AI calls are one prompt each.
struct FallbackModel: AIModel {
    let primary: any AIModel
    let fallback: any AIModel

    var name: String { primary.isAvailable ? primary.name : fallback.name }
    var isAvailable: Bool { primary.isAvailable || fallback.isAvailable }

    func session(tools: [any Tool], instructions: String) -> any AISession {
        guard primary.isAvailable else { return fallback.session(tools: tools, instructions: instructions) }
        return Session(primary: primary.session(tools: tools, instructions: instructions),
                       fallback: { fallback.session(tools: tools, instructions: instructions) })
    }

    struct Session: AISession {
        let primary: any AISession
        let fallback: @Sendable () -> any AISession

        func respond(to prompt: String) async throws -> String {
            do { return try await primary.respond(to: prompt) }
            catch where Self.fallsBack(error) { return try await fallback().respond(to: prompt) }
        }

        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
            do { return try await primary.respond(to: prompt, generating: type) }
            catch where Self.fallsBack(error) { return try await fallback().respond(to: prompt, generating: type) }
        }

        /// A refusal or a guardrail is an answer, not an outage: it doesn't move to the other model.
        static func fallsBack(_ error: any Error) -> Bool {
            !(error is CancellationError) && ![.refusal, .guardrail].contains(AIFailure(error))
        }
    }
}
