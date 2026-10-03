import FoundationModels

/// FIT-8: the weekly review's paragraph. Code works out every number; the model only puts them in words.
enum WeekSummary {
    /// Nil without Apple Intelligence or if the model fails; the review is complete without it.
    static func write(_ facts: [String]) async -> String? {
        guard LanguageModel.isAvailable, !facts.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You are a strength coach writing an athlete's weekly review. Write 2 or 3 short, plain sentences to them.
            Use only the facts given and never invent or change a number. Start with a "Went well" fact if there is
            one, then the one "Needs work" fact that matters most. Never praise a "Needs work" fact, and don't call
            a week good if there's nothing under "Went well". No greeting, no list, no emoji.
            """)
        let text = try? await session.respond(to: facts.joined(separator: "\n")).content
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
