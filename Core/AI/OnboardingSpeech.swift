import Foundation
import FoundationModels

/// Onboarding by voice (FIT-38). The model copies out what was said for the step on screen; code matches names to
/// the catalog, keeps only numbers that were said, and reads dates, days, minutes and body parts itself. Everything
/// it fills in stays dashed until the user touches it.
@Generable
struct SpokenGoals {
    var goals: [Item]

    @Generable
    struct Item {
        @Guide(.anyOf(["weight", "squat", "bench", "deadlift", "pullups", "pushups"]))
        var goal: String
        @Guide(description: "The number they want to reach, only if they said one: body weight in pounds, a lift in pounds, or reps")
        var target: Double?
    }
}

@Generable
struct SpokenExercises {
    @Guide(description: "Exercises or equipment they don't want or don't have, as they said them")
    var without: [String]
    @Guide(description: "Exercises or equipment they like or have, as they said them")
    var with: [String]
}

@Generable
struct SpokenStarts {
    var sets: [Item]
    @Guide(description: "Their age in years, only if said")
    var age: Int?
    @Guide(description: "Their body weight in pounds, only if said")
    var bodyWeight: Double?

    @Generable
    struct Item {
        @Guide(description: "The exercise as they said it")
        var exercise: String
        @Guide(description: "Weight in pounds, only if said")
        var pounds: Double?
        @Guide(description: "Reps, only if said")
        var reps: Double?
        @Guide(description: "Seconds held, only if said")
        var seconds: Double?
    }
}

/// Which step was being answered.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case goals, exercises, starts, schedule
}

enum OnboardingSpeech {
    static func hear(_ text: String, on step: OnboardingStep, into answers: inout OnboardingAnswers, catalog: [Exercise],
                     names: [String: String], now: Date = .now) async throws {
        switch step {
        case .goals:
            let session = LanguageModelSession(instructions: """
                The user says what they want to train for. Copy out each goal they named and its number if they said one.
                weight: losing weight or reaching a body weight. squat, bench, deadlift: lifting more. pullups, pushups: more in a row.
                """)
            let goals = try await session.respond(to: text, generating: SpokenGoals.self).content.goals
            answers.heardGoals(goals.map { ($0.goal, $0.target) }, in: text, now: now)
        case .exercises:
            let session = LanguageModelSession(instructions: """
                The user says which exercises and equipment they want to train with. Copy out the names they said,
                split into the ones they don't want or don't have, and the ones they like or have.
                """)
            let said = try await session.respond(to: text, generating: SpokenExercises.self).content
            answers.heardExercises(without: said.without, with: said.with, catalog: catalog, names: names)
        case .starts:
            let session = LanguageModelSession(instructions: """
                The user says what they can do now: a weight for some reps, how many reps in a row, or how long they hold.
                Copy out only what they said. Never invent numbers.
                """)
            let said = try await session.respond(to: text, generating: SpokenStarts.self).content
            answers.heardStarts(said.sets.map { ($0.exercise, $0.pounds, $0.reps, $0.seconds) }, age: said.age,
                                bodyWeight: said.bodyWeight, in: text, catalog: catalog, names: names)
        case .schedule:
            answers.heardSchedule(text)
        }
    }
}

extension OnboardingAnswers {
    /// Goals said replace the picks; a number counts only if it was said, and a date sets the length.
    mutating func heardGoals(_ goals: [(id: String, target: Double?)], in text: String, now: Date,
                             calendar: Calendar = .current) {
        let said = SpokenNumbers.values(in: text)
        let picked = goals.map(\.id).filter { GoalOption.with(id: $0) != nil }
        if !picked.isEmpty {
            self.goals = picked.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            unconfirmed.insert("goals")
        }
        for goal in goals {
            guard let target = goal.target, said.contains(target), GoalOption.with(id: goal.id) != nil else { continue }
            targets[goal.id] = target
            unconfirmed.insert("target.\(goal.id)")
        }
        if let date = SpokenDates.date(in: text, after: now, calendar: calendar) {
            weeks = min(Self.weekRange.upperBound, max(Self.weekRange.lowerBound,
                        ProgramPlan.weekCount(start: now, target: date, calendar: calendar)))
            unconfirmed.insert("weeks")
        }
    }

    /// Names are matched to the catalog and the equipment list; "no squats" leaves out every squat.
    mutating func heardExercises(without: [String], with: [String], catalog: [Exercise], names: [String: String]) {
        for name in without {
            if let item = Self.equipment(named: name) { equipment.remove(item) }
            for slug in Self.exercises(named: name, catalog: catalog, names: names) {
                avoid.insert(slug)
                unconfirmed.insert("move.\(slug)")
            }
        }
        for name in with {
            if let item = Self.equipment(named: name) { equipment.insert(item) }
            for slug in Self.exercises(named: name, catalog: catalog, names: names) {
                avoid.remove(slug)
                unconfirmed.insert("move.\(slug)")
            }
        }
    }

    mutating func heardStarts(_ sets: [(exercise: String, pounds: Double?, reps: Double?, seconds: Double?)], age: Int?,
                              bodyWeight: Double?, in text: String, catalog: [Exercise], names: [String: String]) {
        let said = SpokenNumbers.values(in: text)
        if let age, said.contains(Double(age)), (13...100).contains(age) {
            self.age = age
            unconfirmed.insert("age")
        }
        if let bodyWeight, said.contains(bodyWeight) {
            weight = bodyWeight
            unconfirmed.insert("weight")
        }
        for set in sets {
            // "Push-ups" and "squat" can name several; the row on screen is the first that matches.
            let rows = startRows(catalog).map(\.id)
            guard let slug = Self.exercises(named: set.exercise, catalog: catalog, names: names)
                .sorted(by: { (rows.firstIndex(of: $0) ?? .max) < (rows.firstIndex(of: $1) ?? .max) }).first,
                  let exercise = catalog.first(where: { $0.slug == slug }) else { continue }
            func kept(_ value: Double?) -> Double? { value.flatMap { said.contains($0) ? $0 : nil } }
            var measurements: [Measurement] = []
            switch Self.measure(exercise) {
            case .hold:
                if let seconds = kept(set.seconds) { measurements = [Measurement(metric: "duration_s", value: seconds, unit: "s")] }
            case .reps:
                if let reps = kept(set.reps) { measurements = [Measurement(metric: "reps", value: reps, unit: "reps")] }
            default:
                // A weight with no reps ("I squat 225") is a single.
                if let pounds = kept(set.pounds) {
                    let reps = kept(set.reps) ?? 1
                    measurements = [Measurement(metric: "load_lb", value: pounds, unit: "lb"),
                                    Measurement(metric: "reps", value: reps, unit: "reps")]
                }
            }
            guard !measurements.isEmpty else { continue }
            starts[slug] = StartingSet(exercise: slug, measurements: measurements)
            avoid.remove(slug)
            unconfirmed.insert("start.\(slug)")
        }
    }

    /// Days, minutes and body parts are short fixed words, so code reads them.
    mutating func heardSchedule(_ text: String) {
        let said = text.lowercased()
        let days = SpokenRequest.weekdays.indices.filter { said.contains(SpokenRequest.weekdays[$0]) }
        if !days.isEmpty {
            self.days = days
            unconfirmed.insert("days")
        }
        if let minutes = SpokenNumbers.minutes(in: said) {
            self.minutes = [30, 45, 60, 75].min { abs($0 - minutes) < abs($1 - minutes) }!
            unconfirmed.insert("minutes")
        }
        let words = said.split { !$0.isLetter }.map(String.init)
        if let area = BodyArea.mentioned(in: words) {
            let key = Self.hurtAreas.first { area.hasPrefix($0.dropLast()) || $0.hasPrefix(area) } ?? area
            hurts.insert(key)
            unconfirmed.insert("hurts")
        }
    }

    /// The areas onboarding offers to work around, as BodyArea keys.
    static let hurtAreas = ["lower back", "knees", "shoulders", "wrists"]

    static let equipmentNames = ["barbell": "Barbell", "rack": "Rack", "bench": "Bench", "dumbbells": "Dumbbells",
                                 "pull_up_bar": "Pull-up bar"]

    /// Equipment said on its own: "a barbell", "dumbbells", "pull-up bar". "Bench press" is an exercise.
    static func equipment(named name: String) -> String? {
        let words = Self.words(name).subtracting(["a", "the", "no", "my", "any", "some", "have", "only"])
        if words.contains("bar"), words.contains("pull") || words.contains("chin") { return "pull_up_bar" }
        guard words.count == 1, let word = words.first else { return nil }
        return ["barbell": "barbell", "rack": "rack", "bench": "bench", "dumbbell": "dumbbells"][word]
    }

    /// Every exercise whose name holds all the words said: "squats" → every squat, "Romanian deadlifts" → the
    /// dumbbell RDL, "front squats" → none.
    static func exercises(named name: String, catalog: [Exercise], names: [String: String]) -> [String] {
        let said = words(name).subtracting(["the", "a", "some", "my", "any", "strict", "in", "row"])
        guard !said.isEmpty else { return [] }
        return catalog.filter { said.isSubset(of: words(names[$0.slug] ?? $0.slug)) }.map(\.slug)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().replacingOccurrences(of: "-", with: " ").split { !$0.isLetter }.map { word in
            let word = String(word)
            return word.count > 2 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        })
    }
}

/// A target date as said: "by the end of February", "March 1st", "in 12 weeks". The next one after `now`.
enum SpokenDates {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                         "october", "november", "december"]

    static func date(in text: String, after now: Date, calendar: Calendar = .current) -> Date? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let unit = words.firstIndex(where: { $0.hasPrefix("week") || $0.hasPrefix("month") }), unit > 0,
           let count = Double(words[unit - 1]) ?? SpokenNumbers.values(in: words[unit - 1]).first {
            return calendar.date(byAdding: words[unit].hasPrefix("week") ? .weekOfYear : .month, value: Int(count), to: now)
        }
        guard let index = words.firstIndex(where: { months.contains($0) }), let month = months.firstIndex(of: words[index]) else {
            return nil
        }
        let next = words.dropFirst(index + 1).first.map { $0.trimmingCharacters(in: .letters) }.flatMap(Int.init)
        let start = words[max(0, index - 3)..<index].contains { $0 == "start" || $0 == "beginning" || $0 == "early" }
        var year = calendar.component(.year, from: now)
        for _ in 0..<2 {
            let first = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1, hour: 12))!
            let date = if let day = next, (1...31).contains(day) {
                calendar.date(from: DateComponents(year: year, month: month + 1, day: day, hour: 12))!
            } else if start {
                first
            } else {
                calendar.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
            }
            if date > now { return date }
            year += 1
        }
        return nil
    }

    /// A trip as said: "November 9 to 20", "from Nov 9 to Nov 20", "December 28 to January 3". The next one after
    /// `now`. Days without a month take the month before them.
    static func range(in text: String, after now: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var found: [(month: Int, day: Int)] = []
        var month: Int?
        for word in words {
            if let index = months.firstIndex(where: { $0 == word || ($0.prefix(3) == word && word.count == 3) }) {
                month = index + 1
            } else if let day = Int(word.trimmingCharacters(in: .letters)), (1...31).contains(day), let month {
                found.append((month, day))
            }
        }
        guard found.count >= 2 else { return nil }
        var year = calendar.component(.year, from: now)
        func date(_ item: (month: Int, day: Int), _ year: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: item.month, day: item.day, hour: 12))!
        }
        if date(found[0], year) < calendar.startOfDay(for: now) { year += 1 }
        let start = date(found[0], year)
        var end = date(found[1], year)
        if end < start { end = date(found[1], year + 1) }
        return (start, end)
    }
}
