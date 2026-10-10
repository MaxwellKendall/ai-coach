import FoundationModels

/// FIT-91: the model an AI call runs on. The app only ever uses `OnDeviceModel` (CLAUDE.md principle 3); the evals
/// run the same code on other models to compare them (FIT-90). Every model takes the same `@Generable` answers and
/// `Tool`s: a schema encodes to JSON Schema, and a model's JSON comes back through `GeneratedContent(json:)`.
protocol AIModel: Sendable {
    /// For eval reports: "on-device", "claude-opus-5-5".
    var name: String { get }
    var isAvailable: Bool { get }
    func session(tools: [any Tool], instructions: String) -> any AISession
}

/// One conversation: each answer sees the turns before it.
protocol AISession: Sendable {
    func respond(to prompt: String) async throws -> String
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content
}

extension AIModel {
    func session(instructions: String) -> any AISession { session(tools: [], instructions: instructions) }
}

/// Apple's on-device model.
struct OnDeviceModel: AIModel {
    var name: String { "on-device" }
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func session(tools: [any Tool], instructions: String) -> any AISession {
        Session(session: LanguageModelSession(tools: tools, instructions: instructions))
    }

    struct Session: AISession {
        let session: LanguageModelSession

        func respond(to prompt: String) async throws -> String {
            try await session.respond(to: prompt).content
        }

        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
            try await session.respond(to: prompt, generating: type).content
        }
    }
}

/// Why a model call failed, whichever model it was. Models other than the on-device one throw these.
enum AIFailure: Error, Equatable {
    case guardrail, refusal, tooLong, other

    init(_ error: any Error) {
        switch error {
        case let error as AIFailure: self = error
        case let error as LanguageModelSession.GenerationError:
            switch error {
            case .guardrailViolation: self = .guardrail
            case .refusal: self = .refusal
            case .exceededContextWindowSize: self = .tooLong
            default: self = .other
            }
        default: self = .other
        }
    }
}
