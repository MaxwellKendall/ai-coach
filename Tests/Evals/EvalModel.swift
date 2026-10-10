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

    private static func model(named variable: String) -> any AIModel {
        let environment = ProcessInfo.processInfo.environment
        let name = environment[variable].flatMap { $0.isEmpty ? nil : $0 } ?? "on-device"
        guard name.hasPrefix("claude") else { return OnDeviceModel() }
        return ClaudeModel(model: name, key: environment["ANTHROPIC_API_KEY"] ?? "",
                           thinking: environment["EVAL_THINKING"].flatMap { Int($0) })
    }

    static func unavailable(_ model: any AIModel) -> String {
        model is ClaudeModel ? "No ANTHROPIC_API_KEY for \(model.name)" : "Apple Intelligence is off on this Mac"
    }

    /// Dollars per million tokens in and out, from platform.claude.com/docs/en/about-claude/pricing (2026-10-10).
    static let prices: [String: (input: Double, output: Double)] = [
        "claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2, 10), "claude-opus-5-5": (4, 20), "claude-fable-5-1": (10, 50),
    ]

    /// What the model's requests so far cost, in dollars: 0 on-device, nil for a model without a price here.
    static func cost(_ model: any AIModel) -> Double? {
        guard let model = model as? ClaudeModel else { return 0 }
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
        guard let model = model as? ClaudeModel else { return nil }
        let used = model.usage.tokens.withLock { $0 }
        func short(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
        return "\(short(used.input)) tokens in, \(short(used.output)) out over \(used.requests) requests"
    }
}
