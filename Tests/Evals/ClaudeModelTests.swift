import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-93: what ClaudeModel sends and reads, without the network.
struct ClaudeModelTests {
    private func contains(_ json: JSON, key: String) -> Bool {
        switch json {
        case .object(let object): object[key] != nil || object.values.contains { contains($0, key: key) }
        case .array(let array): array.contains { contains($0, key: key) }
        default: false
        }
    }

    @Test func designedWeekSchemaIsPlainJSONSchema() throws {
        let schema = try ClaudeModel.inputSchema(ProgramDesigner.DesignedWeek.generationSchema)
        #expect(schema["type"]?.string == "object")
        #expect(!contains(schema, key: "$ref"))
        #expect(!contains(schema, key: "$defs"))
        #expect(!contains(schema, key: "x-order"))
        let item = schema["properties"]?["sessions"]?["items"]?["properties"]?["exercises"]?["items"]
        #expect(item?["properties"]?["sets"]?["minimum"]?.number == 2)
        #expect(item?["properties"]?["sets"]?["maximum"]?.number == 5)
        #expect(item?["required"]?.array?.contains(.string("name")) == true)
    }

    @Test func anAnswerDecodesIntoTheGenerableType() throws {
        let json = #"""
            {"sessions": [{"name": "Upper A", "why": "Heavier bench triples", "exercises": [
                {"name": "Bench Press", "main": true, "sets": 4, "reps": 5, "pounds": 185, "rpe": 8},
                {"name": "Pull-up", "main": false, "sets": 3, "reps": 8}]}]}
            """#
        let week = try ProgramDesigner.DesignedWeek(GeneratedContent(json: json))
        #expect(week.sessions.first?.exercises.first?.pounds == 185)
        #expect(week.sessions.first?.exercises.last?.pounds == nil)
    }

    @Test func wholeNumbersAreSentAsIntegers() throws {
        #expect(try ClaudeModel.encoded(.object(["sets": .number(3), "rpe": .number(7.5)])).contains("\"sets\":3"))
    }
}

/// FIT-98: what OpenAIModel and GeminiModel send, and which model a name picks, without the network.
struct OtherModelsTests {
    @Test func openAIFunctionsAndGeminiDeclarationsCarryThePlainSchema() throws {
        let schema = try ClaudeModel.inputSchema(ProgramDesigner.DesignedWeek.generationSchema)
        let function = OpenAIModel.function("answer", "Give your answer.", schema)
        #expect(function["type"]?.string == "function")
        #expect(function["parameters"] == schema)
        let declaration = GeminiModel.declaration("answer", "Give your answer.", schema)
        #expect(declaration["parametersJsonSchema"] == schema)
    }

    @Test func aNamePicksItsModel() {
        #expect(EvalModel.model("on-device") is OnDeviceModel)
        #expect(EvalModel.model("o3") is OpenAIModel)
        #expect(EvalModel.model("gpt-6-luna") is OpenAIModel)
        #expect(EvalModel.model("claude-haiku-5-5") is ClaudeModel)
        #expect(EvalModel.model("gemini-3.8-flash") is GeminiModel)
    }

    @Test func everyModelHasAPrice() {
        for name in ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "gpt-6-luna", "gpt-6.1-sol", "gemini-3.8-flash", "gemini-3.1-pro-preview"] {
            #expect(EvalModel.prices[name] != nil, "\(name)")
        }
        let model = OpenAIModel(model: "gpt-6-luna", key: "test")
        model.usage.add(input: 1_000_000, output: 1_000_000)
        #expect(EvalModel.cost(model) == 0.6)
        #expect(EvalModel.cost(OnDeviceModel()) == 0)
    }
}

/// FIT-100: what OpenAIDecisions sends and reads, without the network.
struct OpenAIDecisionsTests {
    private let bench = Progression.Lift(
        exercise: "bench-press", name: "Bench Press", plannedLoad: 185, plannedReps: 5,
        sessions: [[LoggedSet(date: .now, exercise: "bench-press", pattern: nil,
                              measurements: [.init(metric: "load_lb", value: 185, unit: "lb"), .init(metric: "reps", value: 5, unit: "reps")])]],
        daysOff: 6, now: nil, aim: nil)

    @Test func oneChoiceQuestionPerLiftWithTheEvidenceAsInput() throws {
        let request = try OpenAIDecisions.request([bench], context: "Last week: 3 of 3 sessions done.", model: "gpt-6-luna", key: "test")
        #expect(request.url?.path == "/v1/decisions")
        let body = try JSONDecoder().decode(JSON.self, from: request.httpBody ?? Data())
        #expect(body["model"]?.string == "gpt-6-luna")
        #expect(body["input"]?.string?.hasPrefix("Last week: 3 of 3 sessions done.\nBench Press: last time, 6 days ago, planned 185 × 5") == true)
        let question = body["questions"]?.array?.first
        #expect(question?["type"]?.string == "choice")
        #expect(question?["name"]?.string == "bench-press")
        #expect(question?["choices"]?.array?.compactMap { $0["value"]?.string } == ["add_more", "add", "hold", "back_off"])
    }

    @Test func answersBecomeDecisionsAndARefusalLeavesTheLift() {
        let response = JSON.object(["answers": .array([
            .object(["type": .string("choice"), "name": .string("bench-press"), "choice": .string("add"), "confidence": .number(0.9)]),
            .object(["type": .string("refusal"), "name": .string("back-squat")]),
        ])])
        let decided = OpenAIDecisions.decisions(response, lifts: [bench])
        #expect(decided["bench-press"]?.load == 190)
        #expect(decided["bench-press"]?.confidence == 0.9)
        #expect(decided["back-squat"] == nil)
    }
}
