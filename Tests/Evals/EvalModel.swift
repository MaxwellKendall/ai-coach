import Foundation
@testable import AICoach

/// FIT-90: the model an eval run scores, from `EVAL_MODEL`: "on-device" (the default) or a Claude model id, with the
/// key in `ANTHROPIC_API_KEY` and an optional thinking budget in `EVAL_THINKING`.
enum EvalModel {
    static func current() -> any AIModel {
        let environment = ProcessInfo.processInfo.environment
        let name = environment["EVAL_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "on-device"
        guard name.hasPrefix("claude") else { return OnDeviceModel() }
        return ClaudeModel(model: name, key: environment["ANTHROPIC_API_KEY"] ?? "",
                           thinking: environment["EVAL_THINKING"].flatMap { Int($0) })
    }

    static func unavailable(_ model: any AIModel) -> String {
        model is ClaudeModel ? "No ANTHROPIC_API_KEY for \(model.name)" : "Apple Intelligence is off on this Mac"
    }

    /// "1.2M in, 85k out over 140 requests", for models that count tokens.
    static func usage(_ model: any AIModel) -> String? {
        guard let model = model as? ClaudeModel else { return nil }
        let used = model.usage.tokens.withLock { $0 }
        func short(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
        return "\(short(used.input)) tokens in, \(short(used.output)) out over \(used.requests) requests"
    }
}
