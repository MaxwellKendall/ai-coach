import Foundation
@testable import AICoach

/// FIT-100: OpenAI's Decisions API (public beta, `POST /v1/decisions`, gpt-6-luna) deciding each main lift's next
/// step: one `choice` question per lift, with the week's evidence code wrote. Eval target only (CLAUDE.md principle 3).
/// Billed for input only.
struct OpenAIDecisions: ProgressionDecider {
    let key: String
    let model = "gpt-6-luna"
    let usage = TokenUsage()
    var name: String { "openai-decisions" }

    /// $0.10 per million input tokens, nothing for output (developers.openai.com/api/docs/guides/decisions, 2026-10-10).
    var cost: Double { Double(usage.tokens.withLock { $0.input }) * 0.10 / 1_000_000 }

    func decide(_ lifts: [Progression.Lift], context: String) async throws -> [String: Progression.Decision] {
        guard !lifts.isEmpty else { return [:] }
        let request = try Self.request(lifts, context: context, model: model, key: key)
        let response = try await APIRequest.send(request, name: "OpenAI Decisions") { json in
            usage.add(input: json["usage"]?["input_tokens"]?.number, output: 0)
        }
        return Self.decisions(response, lifts: lifts)
    }

    static let choices: [(Progression.Step, String)] = [
        (.addMore, "Add more load, about twice the usual step: the lift is behind its goal's line and the last session's reps were all done at or under the target effort."),
        (.add, "Add load: the last session's reps were all done at or under the target effort, with no sign of strain."),
        (.hold, "Keep the same load: a rep was missed once, the effort was very high, or recovery looks short (skipped sessions, poor sleep)."),
        (.backOff, "Reduce the load about 10%: reps were missed in two sessions running, or there's been a long break."),
    ]

    static func request(_ lifts: [Progression.Lift], context: String, model: String, key: String) throws -> URLRequest {
        let questions: [JSON] = lifts.map { lift in
            .object(["type": .string("choice"), "name": .string(lift.exercise),
                     "instructions": .string("What should \(lift.name)'s top set do this week, going by how it went, the week's recovery, and its goal if it has one?"),
                     "choices": .array(choices.map { .object(["value": .string($0.0.rawValue), "description": .string($0.1)]) })])
        }
        let input = ([context] + lifts.map(Progression.evidence)).filter { !$0.isEmpty }.joined(separator: "\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/decisions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSON.object(["model": .string(model), "input": .string(input), "questions": .array(questions)]))
        return request
    }

    /// Each answer's choice as the lift's decision; a refusal or an answer it can't read leaves the lift to the designer.
    static func decisions(_ response: JSON, lifts: [Progression.Lift]) -> [String: Progression.Decision] {
        var decided: [String: Progression.Decision] = [:]
        for answer in response["answers"]?.array ?? [] where answer["type"]?.string == "choice" {
            guard let name = answer["name"]?.string, let lift = lifts.first(where: { $0.exercise == name }),
                  let step = answer["choice"]?.string.flatMap(Progression.Step.init(rawValue:)),
                  let decision = Progression.decision(lift, step: step, confidence: answer["confidence"]?.number ?? 0) else { continue }
            decided[name] = decision
        }
        return decided
    }
}
