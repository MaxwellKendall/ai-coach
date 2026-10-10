import Foundation
import FoundationModels
import Synchronization
@testable import AICoach

/// FIT-98: OpenAI through the Responses API, so the evals can compare its models on the app's own AI code. Eval target
/// only (CLAUDE.md principle 3). Like ClaudeModel: the session's `Tool`s go as functions with their schema as plain JSON
/// Schema, and a structured answer is a call to one more function, `answer`.
struct OpenAIModel: AIModel, MeteredModel {
    /// "gpt-6-luna".
    let model: String
    let key: String
    let usage = TokenUsage()

    var name: String { model }
    var isAvailable: Bool { !key.isEmpty }

    func session(tools: [any Tool], instructions: String) -> any AISession {
        Session(model: self, tools: tools, instructions: instructions)
    }

    final class Session: AISession {
        let model: OpenAIModel
        let tools: [any Tool]
        let instructions: String
        /// The conversation so far as Responses API items; the model's own (reasoning included) as they came back.
        private let items = Mutex<[JSON]>([])

        init(model: OpenAIModel, tools: [any Tool], instructions: String) {
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

        private func user(_ text: String) -> JSON { .object(["role": .string("user"), "content": .string(text)]) }

        private func converse(_ prompt: String, answer schema: GenerationSchema?) async throws -> (text: String, answer: GeneratedContent?) {
            var functions = try tools.map { tool in
                OpenAIModel.function(tool.name, tool.description, try ClaudeModel.inputSchema(tool.parameters))
            }
            if let schema {
                functions.append(OpenAIModel.function("answer", "Give your answer. Call this once, last.", try ClaudeModel.inputSchema(schema)))
            }
            items.withLock { $0.append(user(prompt)) }
            for _ in 0..<12 {
                let response = try await model.send(instructions: instructions, input: items.withLock { $0 }, tools: functions)
                if response["status"]?.string == "incomplete" { throw AIFailure.tooLong }
                let output = response["output"]?.array ?? []
                items.withLock { $0 += output }
                let calls = output.filter { $0["type"]?.string == "function_call" }
                var answer: GeneratedContent?
                for call in calls {
                    let id = call["call_id"]?.string ?? "", name = call["name"]?.string ?? ""
                    let arguments = call["arguments"]?.string ?? "{}"
                    let result: String
                    if name == "answer" {
                        do {
                            answer = try GeneratedContent(json: arguments)
                            result = "Received."
                        } catch {
                            result = "That doesn't match the schema: \(error). Call answer again."
                        }
                    } else if let tool = tools.first(where: { $0.name == name }) {
                        result = (try? await ClaudeModel.call(tool, arguments)) ?? "That search failed."
                    } else {
                        result = "There's no function called \(name)."
                    }
                    items.withLock { $0.append(.object(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(result)])) }
                }
                let messages = output.filter { $0["type"]?.string == "message" }.flatMap { $0["content"]?.array ?? [] }
                if messages.contains(where: { $0["type"]?.string == "refusal" }) { throw AIFailure.refusal }
                let text = messages.compactMap { $0["type"]?.string == "output_text" ? $0["text"]?.string : nil }.joined()
                if let answer { return (text, answer) }
                if calls.isEmpty {
                    guard schema != nil else { return (text, nil) }
                    items.withLock { $0.append(user("Give your answer by calling answer.")) }
                }
            }
            throw AIFailure.other
        }
    }

    static func function(_ name: String, _ description: String, _ parameters: JSON) -> JSON {
        .object(["type": .string("function"), "name": .string(name), "description": .string(description), "parameters": parameters,
                 "strict": .bool(false)])
    }

    /// The Responses API: GPT-6 models only take function tools with reasoning here, not in Chat Completions.
    private func send(instructions: String, input: [JSON], tools: [JSON]) async throws -> JSON {
        var body: [String: JSON] = ["model": .string(model), "instructions": .string(instructions), "input": .array(input),
                                    "max_output_tokens": .number(16_000), "store": .bool(false),
                                    // Not stored, so reasoning goes back to it whole between turns.
                                    "include": .array([.string("reasoning.encrypted_content")])]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            // Not forced, as with every model here (ClaudeModel.send).
            body["tool_choice"] = .string("auto")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSON.object(body))
        return try await APIRequest.send(request, name: "OpenAI") { json in
            // Reasoning bills as output, and is counted in output_tokens.
            usage.add(input: json["usage"]?["input_tokens"]?.number, output: json["usage"]?["output_tokens"]?.number)
        }
    }
}

/// Sending a request to a model's API: rate limits, overload and server errors are retried with backoff; a prompt
/// too long is `AIFailure.tooLong`; anything else is a mistake here and says what the API said.
enum APIRequest {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func send(_ request: URLRequest, name: String, counted: (JSON) -> Void) async throws -> JSON {
        var wait: Duration = .seconds(5)
        for attempt in 1...4 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
            if status == 200 {
                counted(json)
                return json
            }
            let message = json["error"]?["message"]?.string ?? String(decoding: data, as: UTF8.self)
            if message.localizedCaseInsensitiveContains("too long") || message.localizedCaseInsensitiveContains("context length") {
                throw AIFailure.tooLong
            }
            guard [429, 500, 502, 503, 504, 529].contains(status), attempt < 4 else { throw Failure(description: "\(name) \(status): \(message)") }
            try await Task.sleep(for: wait)
            wait *= 2
        }
        throw AIFailure.other
    }
}
