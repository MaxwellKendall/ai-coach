import FoundationModels

enum LanguageModel {
    /// Voice and natural-language entry are hidden when this is false; manual flows always work.
    /// FIT-215: and while the pilot hides the in-app AI.
    static var isAvailable: Bool { Pilot.inAppAI && OnDeviceModel().isAvailable }

    /// FIT-102: Claude Haiku through our server for the program brief and the weeks' design: the cheapest model that
    /// passed the program evals (FIT-98, FIT-100).
    static let cloud = "claude-haiku-5-5"

    /// The model that writes the program brief and designs the weeks: Claude for a signed-in user, falling back to
    /// the on-device model when it can't answer; the on-device model alone when signed out. FIT-215: none while the
    /// pilot hides the in-app AI, so weeks come from the rules.
    static func programs(signedIn: Bool) -> any AIModel {
        guard Pilot.inAppAI else { return NoModel() }
        return FallbackModel(primary: ClaudeModel(model: cloud, transport: ClaudeProxy(signedIn: signedIn)), fallback: OnDeviceModel())
    }
}

/// FIT-215: no model at all; every caller already has a path for an unavailable one.
struct NoModel: AIModel {
    var name: String { "none" }
    var isAvailable: Bool { false }

    func session(tools: [any Tool], instructions: String) -> any AISession { Session() }

    struct Session: AISession {
        struct Off: Error {}
        func respond(to prompt: String) async throws -> String { throw Off() }
        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content { throw Off() }
    }
}
