import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

/// 3:00 PM on 2 June 2026.
private let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 15))!

private var recipes: [Template] { catalog }
nonisolated(unsafe) private let catalog = [
    Template(kind: .recipe, name: "Chicken Burrito Bowl", slug: "chicken-burrito-bowl"),
    Template(kind: .recipe, name: "Chicken Bowl with Rice and Beans", slug: "chicken-bowl-rice-beans"),
    Template(kind: .exercise, name: "Burrito Squat", slug: "burrito-squat"),
]

struct LogParseTests {
    @Test func spokenNameMatchesTheShortestRecipeContainingEveryWord() {
        #expect(LogResolver.match("the chicken bowl", in: recipes)?.slug == "chicken-burrito-bowl")
        #expect(LogResolver.match("burrito", in: recipes)?.slug == "chicken-burrito-bowl")
        #expect(LogResolver.match("a burrito wrap", in: recipes) == nil)
        #expect(LogResolver.match("the", in: recipes) == nil)
    }

    @Test func mealsLinkTheRecipeAndNeverInventMacros() {
        let result = LogResolver.resolve([ParsedLogItem(kind: .meal, name: "chicken bowl", when: .lunch),
                                          ParsedLogItem(kind: .meal, name: "pad thai", when: .lunch)],
                                         recipes: recipes, now: now, calendar: calendar)
        let (bowl, thai) = (result.entries[0], result.entries[1])
        #expect(bowl.templateRef == recipes[0].id && bowl.note == "Chicken Burrito Bowl")
        #expect(bowl.measurements == [Measurement(metric: "servings", value: 1, unit: "servings")])
        #expect(thai.templateRef == nil && thai.note == "pad thai")
        #expect(thai.measurements.isEmpty && thai.isValid) // saves with just a name
        #expect(calendar.component(.hour, from: bowl.timestamp) == 12)
    }

    @Test func statedMacrosAreKeptAndNothingElse() {
        let result = LogResolver.resolve([ParsedLogItem(kind: .meal, name: "protein shake", kcal: 300, proteinG: 40)],
                                         recipes: recipes, now: now, calendar: calendar)
        #expect(result.entries[0].measurements == [Measurement(metric: "kcal", value: 300, unit: "kcal"),
                                                   Measurement(metric: "protein_g", value: 40, unit: "g")])
    }

    @Test func sleepWeightAndGroceriesBecomeTheirKinds() {
        let result = LogResolver.resolve([ParsedLogItem(kind: .sleep, hours: 6, quality: 2),
                                          ParsedLogItem(kind: .weight, weightLb: 181.4),
                                          ParsedLogItem(kind: .grocery, costUsd: 84)],
                                         recipes: recipes, now: now, calendar: calendar)
        #expect(result.entries.map(\.kind) == [.sleep, .bodyweight, .grocery])
        #expect(result.entries[0].measurements == [Measurement(metric: "sleep_h", value: 6, unit: "h"),
                                                   Measurement(metric: "sleep_quality", value: 2, unit: "/5")])
        #expect(result.entries[0].fields[1].inferred)
        #expect(result.entries[1].measurements == [Measurement(metric: "weight_lb", value: 181.4, unit: "lb")])
        #expect(result.entries[2].measurements == [Measurement(metric: "cost_usd", value: 84, unit: "$")])
    }

    @Test func workoutsMakeNoEntryAndMissingValuesCannotSave() {
        let result = LogResolver.resolve([ParsedLogItem(kind: .workout), ParsedLogItem(kind: .sleep)],
                                         recipes: recipes, now: now, calendar: calendar)
        #expect(result.mentionedWorkout)
        #expect(result.entries.count == 1 && !result.entries[0].isValid) // sleep with no hours
        #expect(!LogDraftEntry.blank(.meal).isValid)
    }

    @Test func timesNeverLandInTheFutureAndYesterdayIsADayBack() {
        #expect(LogResolver.time(.dinner, now: now, calendar: calendar) == now) // 6:30 PM hasn't happened yet
        #expect(calendar.component(.hour, from: LogResolver.time(.breakfast, now: now, calendar: calendar)) == 8)
        #expect(calendar.component(.day, from: LogResolver.time(.yesterday, now: now, calendar: calendar)) == 1)
    }

    @Test func savedEntryCarriesTheCardsValues() {
        var card = LogDraftEntry.blank(.grocery, at: now)
        card.set("cost_usd", 84)
        let entry = card.makeEntry()
        #expect(entry.kind == .grocery && entry.timestamp == now)
        #expect(entry.measurements == card.measurements)
    }

    @Test func newKindsReadNaturallyOnTheDayPage() {
        #expect(Measurement(metric: "servings", value: 1, unit: "servings").display == "×1")
        #expect(Measurement(metric: "cost_usd", value: 84, unit: "$").display == "$84")
        #expect(Measurement(metric: "sleep_h", value: 6.5, unit: "h").display == "6.5 h")
    }
}
