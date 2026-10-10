import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import AICoach

/// FIT-102: Claude's conversation loop against a scripted server, and falling back to the on-device model.
struct CloudModelTests {
    /// Answers each request with the next scripted reply, and keeps what was sent.
    final class Script: ClaudeTransport {
        let replies: Mutex<[(Int, JSON)]>
        let sent = Mutex<[JSON]>([])
        init(_ replies: [(Int, JSON)]) { self.replies = Mutex(replies) }
        var isAvailable: Bool { true }
        func send(_ body: JSON) async throws -> (status: Int, body: JSON) {
            sent.withLock { $0.append(body) }
            return replies.withLock { $0.removeFirst() }
        }
    }

    @Generable struct Pick {
        var lift: String
        var sets: Int
    }

    private static func toolUse(_ id: String, _ name: String, _ input: JSON) -> JSON {
        .object(["content": .array([.object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])]),
                 "stop_reason": .string("tool_use"), "usage": .object(["input_tokens": .number(100), "output_tokens": .number(20)])])
    }

    @Test func aStructuredAnswerComesBackThroughTheAnswerTool() async throws {
        let script = Script([(200, Self.toolUse("t1", "answer", .object(["lift": .string("Bench Press"), "sets": .number(4)])))])
        let model = ClaudeModel(model: "claude-haiku-5-5", transport: script)
        let pick = try await model.session(instructions: "Pick a lift.").respond(to: "Upper day", generating: Pick.self)
        #expect(pick.lift == "Bench Press")
        #expect(pick.sets == 4)
        let sent = try #require(script.sent.withLock { $0.first })
        #expect(sent["model"]?.string == "claude-haiku-5-5")
        #expect(sent["system"]?.string == "Pick a lift.")
        #expect(sent["tools"]?.array?.compactMap { $0["name"]?.string } == ["answer"])
        #expect(model.usage.tokens.withLock { $0.input } == 100)
    }

    @Test func overloadIsRetriedAndATextReplyIsAskedForTheAnswer() async throws {
        let text = JSON.object(["content": .array([.object(["type": .string("text"), "text": .string("Let me think.")])]),
                                "stop_reason": .string("end_turn")])
        let script = Script([(529, .object(["error": .object(["message": .string("Overloaded")])])), (200, text),
                             (200, Self.toolUse("t2", "answer", .object(["lift": .string("Deadlift"), "sets": .number(3)])))])
        let model = ClaudeModel(model: "claude-haiku-5-5", transport: script)
        let pick = try await model.session(instructions: "Pick a lift.").respond(to: "Lower day", generating: Pick.self)
        #expect(pick.lift == "Deadlift")
        let last = try #require(script.sent.withLock { $0.last })
        #expect(last["messages"]?.array?.last?["content"]?.array?.first?["text"]?.string == "Give your answer by calling answer.")
    }

    @Test func aPromptTooLongIsReadAsTooLong() async {
        let script = Script([(400, .object(["error": .object(["message": .string("prompt is too long: 210000 tokens")])]))])
        let model = ClaudeModel(model: "claude-haiku-5-5", transport: script)
        await #expect(throws: AIFailure.tooLong) {
            _ = try await model.session(instructions: "x").respond(to: "y")
        }
    }

    // MARK: Falling back

    struct Fixed: AIModel {
        var name: String
        var isAvailable = true
        var failure: AIFailure?
        func session(tools: [any Tool], instructions: String) -> any AISession { Answer(name: name, failure: failure) }
        struct Answer: AISession {
            var name: String
            var failure: AIFailure?
            func respond(to prompt: String) async throws -> String {
                if let failure { throw failure }
                return name
            }
            func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content { throw AIFailure.other }
        }
    }

    @Test func aFailedCallFallsBackButARefusalDoesNot() async throws {
        let onDevice = Fixed(name: "on-device")
        #expect(try await FallbackModel(primary: Fixed(name: "claude"), fallback: onDevice).session(instructions: "").respond(to: "") == "claude")
        #expect(try await FallbackModel(primary: Fixed(name: "claude", failure: .other), fallback: onDevice).session(instructions: "").respond(to: "") == "on-device")
        #expect(try await FallbackModel(primary: Fixed(name: "claude", isAvailable: false), fallback: onDevice).session(instructions: "").respond(to: "") == "on-device")
        await #expect(throws: AIFailure.refusal) {
            _ = try await FallbackModel(primary: Fixed(name: "claude", failure: .refusal), fallback: onDevice).session(instructions: "").respond(to: "")
        }
    }

    @Test func signedOutProgramsAreOnDevice() {
        #expect(LanguageModel.programs(signedIn: false).name == "on-device")
        #expect((LanguageModel.programs(signedIn: true) as? FallbackModel)?.primary.name == "claude-haiku-5-5")
    }
}
