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
