import Foundation
import FoundationModels
import Synchronization
@testable import AICoach

/// FIT-98: Gemini through generateContent, so the evals can compare its models on the app's own AI code. Eval target
/// only (CLAUDE.md principle 3). Like ClaudeModel: the session's `Tool`s go as function declarations with their schema
/// as JSON Schema (`parametersJsonSchema`), and a structured answer is a call to one more function, `answer`. The
/// model's turns are kept as they came back, so its thought signatures go back with them.
struct GeminiModel: AIModel, MeteredModel {
    /// "gemini-3.8-flash".
    let model: String
    let key: String
    let usage = TokenUsage()

    var name: String { model }
    var isAvailable: Bool { !key.isEmpty }

    func session(tools: [any Tool], instructions: String) -> any AISession {
        Session(model: self, tools: tools, instructions: instructions)
    }

    final class Session: AISession {
        let model: GeminiModel
        let tools: [any Tool]
        let instructions: String
        private let contents = Mutex<[JSON]>([])
        /// Function responses owed for the last turn's calls; they open the next user turn.
        private let owed = Mutex<[JSON]>([])

        init(model: GeminiModel, tools: [any Tool], instructions: String) {
            self.model = model
            self.tools = tools
            self.instructions = instructions
        }

        func respond(to prompt: String) async throws -> String {
            try await converse(prompt, answer: nil).text
        }

        func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
            guard let answer = try await converse(prompt, answer: Content.generationSchema).answer else { throw AIFailure.other }
            return try Content(answer)
        }

        private func converse(_ prompt: String, answer schema: GenerationSchema?) async throws -> (text: String, answer: GeneratedContent?) {
            var declarations = try tools.map { tool in
                GeminiModel.declaration(tool.name, tool.description, try ClaudeModel.inputSchema(tool.parameters))
            }
            if let schema {
                declarations.append(GeminiModel.declaration("answer", "Give your answer. Call this once, last.", try ClaudeModel.inputSchema(schema)))
            }
            append(user: [.object(["text": .string(prompt)])])
            for _ in 0..<12 {
                let response = try await model.send(system: instructions, contents: contents.withLock { $0 }, declarations: declarations)
                if response["promptFeedback"]?["blockReason"] != nil { throw AIFailure.guardrail }
                guard let candidate = response["candidates"]?.array?.first, let content = candidate["content"] else { throw AIFailure.other }
                switch candidate["finishReason"]?.string {
                case "MAX_TOKENS": throw AIFailure.tooLong
                case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST": throw AIFailure.guardrail
                default: break
                }
                contents.withLock { $0.append(content) }
                let parts = content["parts"]?.array ?? []
                let calls = parts.compactMap { $0["functionCall"] }
                var responses: [JSON] = [], answer: GeneratedContent?
                for call in calls {
                    let name = call["name"]?.string ?? ""
                    let arguments = try ClaudeModel.encoded(call["args"] ?? .object([:]))
                    let output: String
                    if name == "answer" {
                        do {
                            answer = try GeneratedContent(json: arguments)
                            output = "Received."
                        } catch {
                            output = "That doesn't match the schema: \(error). Call answer again."
                        }
                    } else if let tool = tools.first(where: { $0.name == name }) {
                        output = (try? await ClaudeModel.call(tool, arguments)) ?? "That search failed."
                    } else {
                        output = "There's no function called \(name)."
                    }
                    var reply: [String: JSON] = ["name": .string(name), "response": .object(["result": .string(output)])]
                    if let id = call["id"] { reply["id"] = id }
                    responses.append(.object(["functionResponse": .object(reply)]))
                }
                let text = parts.compactMap { $0["thought"] == .bool(true) ? nil : $0["text"]?.string }.joined()
                if let answer {
                    owed.withLock { $0 = responses }
                    return (text, answer)
                }
                if calls.isEmpty {
                    guard schema != nil else { return (text, nil) }
                    append(user: [.object(["text": .string("Give your answer by calling answer.")])])
                } else {
                    append(user: responses)
                }
            }
            throw AIFailure.other
        }

        private func append(user parts: [JSON]) {
            let owed = owed.withLock { owed in defer { owed = [] }; return owed }
            contents.withLock { $0.append(.object(["role": .string("user"), "parts": .array(owed + parts)])) }
        }
    }

    static func declaration(_ name: String, _ description: String, _ schema: JSON) -> JSON {
        .object(["name": .string(name), "description": .string(description), "parametersJsonSchema": schema])
    }

    private func send(system: String, contents: [JSON], declarations: [JSON]) async throws -> JSON {
        var body: [String: JSON] = ["systemInstruction": .object(["parts": .array([.object(["text": .string(system)])])]),
                                    "contents": .array(contents), "generationConfig": .object(["maxOutputTokens": .number(16_000)])]
        if !declarations.isEmpty {
            body["tools"] = .array([.object(["functionDeclarations": .array(declarations)])])
            // Not forced, as with every model here (ClaudeModel.send).
            body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": .string("AUTO")])])
        }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSON.object(body))
        return try await APIRequest.send(request, name: "Gemini") { json in
            let used = json["usageMetadata"]
            // Thinking bills as output.
            usage.add(input: used?["promptTokenCount"]?.number,
                      output: (used?["candidatesTokenCount"]?.number ?? 0) + (used?["thoughtsTokenCount"]?.number ?? 0))
        }
    }
}
