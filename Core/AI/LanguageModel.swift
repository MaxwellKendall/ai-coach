import FoundationModels

enum LanguageModel {
    /// Voice and natural-language entry are hidden when this is false; manual flows always work.
    static var isAvailable: Bool { OnDeviceModel().isAvailable }

    /// FIT-102: Claude Haiku through our server for the program brief and the weeks' design: the cheapest model that
    /// passed the program evals (FIT-98, FIT-100).
    static let cloud = "claude-haiku-5-5"

    /// The model that writes the program brief and designs the weeks: Claude for a signed-in user, falling back to
    /// the on-device model when it can't answer; the on-device model alone when signed out.
    static func programs(signedIn: Bool) -> any AIModel {
        FallbackModel(primary: ClaudeModel(model: cloud, transport: ClaudeProxy(signedIn: signedIn)), fallback: OnDeviceModel())
    }
}
