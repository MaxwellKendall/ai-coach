import Foundation
import FoundationModels
import Synchronization

/// FIT-93, FIT-102: Claude through the Messages API. The app sends each request through our own server (`ClaudeProxy`,
/// which holds the key); the evals send it straight to the API (`ClaudeAPI`, eval target), so they run the same code
/// the app does.
///
/// The session's `Tool`s go to Claude with their `GenerationSchema` as JSON Schema; a structured answer is a call to
/// one more tool, `answer`, whose input schema is the answer's, decoded back through `GeneratedContent(json:)`.
struct ClaudeModel: AIModel {
    /// "claude-haiku-5-5".
    let model: String
    let transport: any ClaudeTransport
    /// Extended thinking's token budget; nil for none.
    var thinking: Int?
    /// Tokens used by every session of this model, for the evals' report.
    let usage = TokenUsage()

    var name: String { thinking.map { "\(model)-thinking-\($0)" } ?? model }
    var isAvailable: Bool { transport.isAvailable }

    func session(tools: [any Tool], instructions: String) -> any AISession {
        Session(model: self, tools: tools, instructions: instructions)
    }

    // MARK: Session

    final class Session: AISession {
        let model: ClaudeModel
        let tools: [any Tool]
        let instructions: String
        /// The conversation so far, as Messages API turns. Claude's own turns are kept exactly as they came back
        /// (thinking blocks must be).
        private let messages = Mutex<[JSON]>([])
        /// Results owed for the last turn's tool calls; they open the next user turn.
        private let owed = Mutex<[JSON]>([])

        init(model: ClaudeModel, tools: [any Tool], instructions: String) {
            self.model = model
            self.tools = tools
            self.instructions = instructions
        }

        func respond(to prompt: String) async throws -> String {
            try await converse(prompt, answer: nil).text
        }

        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
            let answer = try await converse(prompt, answer: Content.generationSchema).answer
            guard let answer else { throw AIFailure.other }
            return try Content(answer)
        }

        /// Turns until Claude stops calling tools, or, when an answer is wanted, until it calls `answer` with input
        /// that decodes.
        private func converse(_ prompt: String, answer schema: GenerationSchema?) async throws -> (text: String, answer: GeneratedContent?) {
            var definitions = try tools.map { tool -> JSON in
                .object(["name": .string(tool.name), "description": .string(tool.description),
                         "input_schema": try ClaudeModel.inputSchema(tool.parameters)])
            }
            if let schema {
                definitions.append(.object(["name": .string("answer"), "description": .string("Give your answer. Call this once, last."),
                                            "input_schema": try ClaudeModel.inputSchema(schema)]))
            }
            append(user: [.object(["type": .string("text"), "text": .string(prompt)])])
            for _ in 0..<12 {
                let response = try await model.send(system: instructions, messages: messages.withLock { $0 }, tools: definitions)
                let content = response["content"]?.array ?? []
                messages.withLock { $0.append(.object(["role": .string("assistant"), "content": .array(content)])) }
                switch response["stop_reason"]?.string {
                case "refusal": throw AIFailure.refusal
                case "max_tokens": throw AIFailure.tooLong
                default: break
                }
                let calls = content.filter { $0["type"]?.string == "tool_use" }
                var results: [JSON] = [], answer: GeneratedContent?
                for call in calls {
                    let id = call["id"]?.string ?? "", name = call["name"]?.string ?? ""
                    let input = try call["input"].map(ClaudeModel.encoded) ?? "{}"
                    if name == "answer" {
                        do {
                            let content = try GeneratedContent(json: input)
                            answer = content
                            results.append(ClaudeModel.result(id, "Received."))
                        } catch {
                            results.append(ClaudeModel.result(id, "That doesn't match the schema: \(error). Call answer again.", error: true))
                        }
                    } else if let tool = tools.first(where: { $0.name == name }) {
                        do { results.append(ClaudeModel.result(id, try await ClaudeModel.call(tool, input))) }
                        catch { results.append(ClaudeModel.result(id, "\(error)", error: true)) }
                    } else {
                        results.append(ClaudeModel.result(id, "There's no tool called \(name).", error: true))
                    }
                }
                let text = content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
                if let answer {
                    owed.withLock { $0 = results }
                    return (text, answer)
                }
                if calls.isEmpty {
                    guard schema != nil else { return (text, nil) }
                    append(user: [.object(["type": .string("text"), "text": .string("Give your answer by calling answer.")])])
                } else {
                    append(user: results)
                }
            }
            throw AIFailure.other
        }

        private func append(user content: [JSON]) {
            let owed = owed.withLock { owed in defer { owed = [] }; return owed }
            messages.withLock { $0.append(.object(["role": .string("user"), "content": .array(owed + content)])) }
        }
    }

    // MARK: Requests

    private func send(system: String, messages: [JSON], tools: [JSON]) async throws -> JSON {
        var body: [String: JSON] = ["model": .string(model), "max_tokens": .number(Double(8_000 + (thinking ?? 0))),
                                    "system": .string(system), "messages": .array(messages)]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        // No forced tool call: Sonnet and Opus 5.5 don't take one ("tool_choice: any … not supported"), so every model
        // is asked the same way, and the "Give your answer" turn does that job.
        if let thinking { body["thinking"] = .object(["type": .string("enabled"), "budget_tokens": .number(Double(thinking))]) }
        var wait: Duration = .seconds(5)
        for attempt in 1...4 {
            let (status, json) = try await transport.send(.object(body))
            if status == 200 {
                if let used = json["usage"] {
                    usage.add(input: used["input_tokens"]?.number, output: used["output_tokens"]?.number)
                }
                return json
            }
            let message = json["error"]?["message"]?.string ?? "no message"
            if message.contains("prompt is too long") { throw AIFailure.tooLong }
            // Rate limits, overload and server errors pass; anything else is a mistake here.
            guard [429, 500, 502, 503, 529].contains(status), attempt < 4 else {
                throw Failure(description: "Claude \(status): \(message)")
            }
            try await Task.sleep(for: wait)
            wait *= 2
        }
        throw AIFailure.other
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func result(_ id: String, _ text: String, error: Bool = false) -> JSON {
        .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(error)])
    }

    static func call<T: Tool>(_ tool: T, _ json: String) async throws -> String {
        let output = try await tool.call(arguments: T.Arguments(GeneratedContent(json: json)))
        return (output as? String) ?? String(describing: output)
    }

    static func encoded(_ json: JSON) throws -> String {
        String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
    }

    /// A `GenerationSchema` as the plain JSON Schema a tool takes: nested types inlined from `$defs`, and Apple's own
    /// `x-order` key dropped.
    static func inputSchema(_ schema: GenerationSchema) throws -> JSON {
        let json = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(schema))
        guard case .object(var root) = json else { return json }
        let definitions = root.removeValue(forKey: "$defs")?.object ?? [:]
        func inline(_ json: JSON) -> JSON {
            switch json {
            case .object(let object):
                if let reference = object["$ref"]?.string, reference.hasPrefix("#/$defs/"),
                   let definition = definitions[String(reference.dropFirst("#/$defs/".count))] {
                    return inline(definition)
                }
                return .object(object.filter { $0.key != "x-order" }.mapValues(inline))
            case .array(let array): return .array(array.map(inline))
            default: return json
            }
        }
        return inline(.object(root))
    }
}

/// How a Messages API request reaches Claude: the HTTP status and the body that came back.
protocol ClaudeTransport: Sendable {
    var isAvailable: Bool { get }
    func send(_ body: JSON) async throws -> (status: Int, body: JSON)
}

/// Tokens a model's requests used: the evals' cost per model.
final class TokenUsage: Sendable {
    let tokens = Mutex<(input: Int, output: Int, requests: Int)>((0, 0, 0))

    func add(input: Double?, output: Double?) {
        tokens.withLock {
            $0.input += Int(input ?? 0)
            $0.output += Int(output ?? 0)
            $0.requests += 1
        }
    }
}
