import Foundation
@testable import AICoach

/// FIT-90: the model an eval run scores, from `EVAL_MODEL`: "on-device" (the default) or a Claude model id, with the
/// key in `ANTHROPIC_API_KEY` and an optional thinking budget in `EVAL_THINKING`.
enum EvalModel {
    static func current() -> any AIModel { model(named: "EVAL_MODEL") }

    /// FIT-98: the model that writes the program brief, from `EVAL_BRIEF_MODEL`; the weeks' model when unset.
    static func brief() -> any AIModel {
        ProcessInfo.processInfo.environment["EVAL_BRIEF_MODEL"].flatMap { $0.isEmpty ? nil : $0 } == nil ? current() : model(named: "EVAL_BRIEF_MODEL")
    }

    /// "on-device", a Claude id ("claude-…"), an OpenAI id ("gpt-…", "o…") or a Gemini id ("gemini-…"), each with its
    /// key from the environment (`.env`, through scripts/program-eval.sh).
    private static func model(named variable: String) -> any AIModel {
        model(ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? "on-device")
    }

    static func model(_ name: String) -> any AIModel {
        let environment = ProcessInfo.processInfo.environment
        let key = { (names: [String]) in names.lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? "" }
        if name.hasPrefix("claude") {
            return ClaudeModel(model: name, transport: ClaudeAPI(key: key(["ANTHROPIC_API_KEY"])), thinking: environment["EVAL_THINKING"].flatMap { Int($0) })
        }
        // "o3", "o4-mini": OpenAI's o-series; not "on-device".
        if name.hasPrefix("gpt") || (name.first == "o" && name.dropFirst().first?.isNumber == true) { return OpenAIModel(model: name, key: key(["OPENAI_API_KEY", "OPEN_AI_API_KEY"])) }
        if name.hasPrefix("gemini") { return GeminiModel(model: name, key: key(["GEMINI_API_KEY"])) }
        return OnDeviceModel()
    }

    /// FIT-100: what decides each main lift's next step before a week is designed, from `EVAL_DECIDER`: "rules",
    /// "openai" (the Decisions API), or nothing (the designer decides, as before).
    static func decider(tier: AgeTier) -> (any ProgressionDecider)? {
        let environment = ProcessInfo.processInfo.environment
        switch environment["EVAL_DECIDER"] ?? "" {
        case "rules": return Progression.Rules(tier: tier)
        case "openai": return OpenAIDecisions(key: [environment["OPENAI_API_KEY"], environment["OPEN_AI_API_KEY"]].compactMap { $0 }.first { !$0.isEmpty } ?? "")
        default: return nil
        }
    }

    static func unavailable(_ model: any AIModel) -> String {
        switch model {
        case is ClaudeModel: "No ANTHROPIC_API_KEY for \(model.name)"
        case is OpenAIModel: "No OPENAI_API_KEY for \(model.name)"
        case is GeminiModel: "No GEMINI_API_KEY for \(model.name)"
        default: "Apple Intelligence is off on this Mac"
        }
    }

    /// Dollars per million tokens in and out, standard tier, short prompts (2026-10-10): Claude from
    /// platform.claude.com/docs/en/about-claude/pricing, OpenAI from developers.openai.com/api/docs/pricing, Gemini from
    /// ai.google.dev/gemini-api/docs/pricing (Flash rates through 2026). Thinking and reasoning tokens bill as output.
    static let prices: [String: (input: Double, output: Double)] = [
        "claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2, 10), "claude-opus-5-5": (4, 20), "claude-fable-5-1": (10, 50),
        "gpt-6-luna": (0.10, 0.50), "gpt-6-sol": (2, 10), "gpt-6.1-sol": (2, 10), "gpt-6-astra": (10, 50), "gpt-5.6-luna": (0.20, 1.20),
        "gpt-5-nano": (0.05, 0.40), "gpt-5-mini": (0.25, 2),
        "gemini-2.5-flash-lite": (0.10, 0.40), "gemini-3.1-flash-lite": (0.25, 1.50), "gemini-3.8-flash": (0.75, 3.75),
        "gemini-3.6-flash": (0.75, 3.75), "gemini-3.1-pro-preview": (2, 12), "gemini-2.5-pro": (1.25, 10),
    ]

    /// What the model's requests so far cost, in dollars: 0 on-device, nil for a model without a price here.
    static func cost(_ model: any AIModel) -> Double? {
        guard let model = model as? any MeteredModel else { return 0 }
        guard let price = prices[model.model] else { return nil }
        let used = model.usage.tokens.withLock { $0 }
        return (Double(used.input) * price.input + Double(used.output) * price.output) / 1_000_000
    }

    static func dollars(_ value: Double?) -> String {
        guard let value else { return "?" }
        return value == 0 ? "$0" : value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.3f", value)
    }

    /// "1.2M in, 85k out over 140 requests", for models that count tokens.
    static func usage(_ model: any AIModel) -> String? {
        guard let model = model as? any MeteredModel else { return nil }
        let used = model.usage.tokens.withLock { $0 }
        func short(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
        return "\(short(used.input)) tokens in, \(short(used.output)) out over \(used.requests) requests"
    }
}

/// A model behind an API, which counts the tokens its requests use.
protocol MeteredModel: AIModel {
    var model: String { get }
    var usage: TokenUsage { get }
}
