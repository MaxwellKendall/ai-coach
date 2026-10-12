import Foundation
import FoundationModels
import Synchronization

/// FIT-103: talking with the coach about this week or the program. Each turn the model answers in words, asks a
/// question back, or calls tools; code makes every change, into one draft that waits for Apply (principle 7). A turn
/// sends only the scope's tools, its context, the draft so far and the last turn, so its size stays fixed.
/// Today's session stays with the spoken edits (FIT-47/49): on-device, applied at once.
enum CoachChat {
    enum Scope: String, CaseIterable, Sendable {
        case session, week, program

        var title: String {
            switch self {
            case .session: "This session"
            case .week: "This week"
            case .program: "Program"
            }
        }
    }

    /// What the coach knows going into a turn.
    struct Context: Sendable {
        var now: Date
        var settings: TrainingSettings
        var catalog: [Exercise]
        var names: [String: String]
        var history: [LoggedSet]
        /// This week from today on, days not done yet.
        var week: [PlannedWorkout]
        var goals: [String]
        /// The program, when there is one: its weeks, start and the brief's phases as lines.
        var program: [ProgramWeek]?
        var programStart: Date?
        var targetDate: Date?
        var travelWeeks: [Int] = []
        var phases: [String] = []
        var calendar: Calendar = .current
    }

    /// The changes waiting for Apply. A nil field is unchanged.
    struct Draft: Equatable, Sendable {
        var week: [PlannedWorkout]?
        var trainingDays: [Int]?
        var sessionMinutes: Int?
        var targetDate: Date?
        var travelWeeks: [Int]?
        /// What changes, one line each, written by code.
        var lines: [String] = []

        var isEmpty: Bool { lines.isEmpty }
    }

    struct Turn: Equatable, Sendable {
        var said: String
        var reply: String
    }

    struct Reply: Sendable {
        var text: String
        var draft: Draft
        /// The tool calls, for the evals.
        var calls: [String]
    }

    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    // MARK: A turn

    static func respond(_ said: String, scope: Scope, context: Context, draft: Draft, last: Turn?,
                        model: any AIModel) async throws -> Reply {
        let state = State(draft: draft, context: context, said: said)
        let tools = scope == .program ? programTools(state) : weekTools(state)
        let session = model.session(tools: tools, instructions: instructions(scope, context: context, draft: draft, last: last))
        var text = try await session.respond(to: said).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = state.draft.withLock { $0 }
        // A change code refused, and nothing else changed: code's words, not the model's retelling of them (the
        // on-device model read "tell them…" back to the user).
        if after == draft, let problem = state.problems.withLock({ $0.last }) { text = problem }
        return Reply(text: text, draft: after, calls: state.calls.withLock { $0 })
    }

    static func instructions(_ scope: Scope, context: Context, draft: Draft, last: Turn?) -> String {
        var lines = [
            "You are the user's strength coach, in their training app. You're talking about \(scope == .program ? "their whole program" : "their training this week").",
            "Answer questions in one to three short sentences, in plain words, from what's below. Never make up numbers.",
            "When they ask for a change your tools can make, call the tools, then say in one sentence what will change when they tap Apply (nothing has changed until then).",
            "If what they want isn't clear, ask one short question instead of changing anything.",
            "If your tools can't make it, say so in a sentence and say what you can do.",
            "Today is \(context.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).",
        ]
        lines.append("Goals: \(context.goals.isEmpty ? "none set" : context.goals.joined(separator: "; ")).")
        lines.append("Trains \(Week.ordered(context.settings.trainingDays).map { dayNames[$0] }.joined(separator: ", ")), \(context.settings.sessionMinutes) minutes a session.")
        if let program = context.program, let start = context.programStart {
            let index = ProgramPlan.week(of: context.now, start: start, calendar: context.calendar)
            let target = context.targetDate.map { ", ending \($0.formatted(.dateTime.month(.wide).day().year()))" } ?? ""
            lines.append("Program: \(program.count) weeks\(target); this is week \(index + 1). Weeks: "
                         + program.enumerated().map { "\($0.offset + 1) \(ProgramPlan.title($0.element).lowercased())" }.joined(separator: ", ") + ".")
            if !context.phases.isEmpty { lines.append("Phases: " + context.phases.joined(separator: " ")) }
        }
        lines.append("The rest of this week: " + weekText(draft.week ?? context.week, context: context))
        if !draft.isEmpty { lines.append("Changes already waiting for Apply: " + draft.lines.joined(separator: " ")) }
        if let last { lines.append("They last said: \"\(last.said)\". You answered: \"\(last.reply)\"") }
        return lines.joined(separator: "\n")
    }

    /// "Wednesday Upper body: Bench Press 4×5 185 lb, …; Friday …", or that nothing's left.
    static func weekText(_ week: [PlannedWorkout], context: Context) -> String {
        let days = Dictionary(grouping: week.filter { $0.note != TrainingGenerator.warmupNote }) { context.calendar.startOfDay(for: $0.date) }
        guard !days.isEmpty else { return "nothing planned." }
        return days.keys.sorted().map { day in
            let rows = days[day]!
            return "\(day.formatted(.dateTime.weekday(.wide))) \(rows[0].session): "
                + rows.map { "\(context.names[$0.exercise] ?? $0.exercise) \(Coach.targets($0.targets))" }.joined(separator: ", ")
        }.joined(separator: "; ") + "."
    }

    // MARK: Tools

    final class State: Sendable {
        let draft: Mutex<Draft>
        let calls = Mutex<[String]>([])
        /// Why a change wasn't made, in words for the user.
        let problems = Mutex<[String]>([])
        let context: Context
        let said: String
        init(draft: Draft, context: Context, said: String = "") {
            self.draft = Mutex(draft)
            self.context = context
            self.said = said
        }
    }

    struct ChatTool: Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let state: State
        let act: @Sendable (GeneratedContent, inout Draft) throws -> String?

        func call(arguments: GeneratedContent) async throws -> String {
            if state.calls.withLock({ $0.count >= 8 }) { return "That's enough changes; answer them now." }
            state.calls.withLock { $0.append("\(name) \(arguments.jsonString)") }
            return state.draft.withLock { draft in
                do {
                    if let problem = try act(arguments, &draft) {
                        state.problems.withLock { $0.append(problem) }
                        return "Not changed. Tell them: \(problem)"
                    }
                    return "Done: \(draft.lines.last ?? "changed")"
                } catch {
                    return "Those arguments didn't work: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func choice(_ name: String, _ description: String, _ choices: [String]) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: DynamicGenerationSchema(name: name, anyOf: choices))
    }

    private static func text(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
    }

    private static func number(_ name: String, _ description: String, _ range: ClosedRange<Int>) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: DynamicGenerationSchema(type: Int.self, guides: [.range(range)]))
    }

    private static func make(_ name: String, _ description: String, _ properties: [DynamicGenerationSchema.Property], _ state: State,
                             _ act: @escaping @Sendable (GeneratedContent, inout Draft) throws -> String?) -> (any Tool)? {
        guard let schema = try? GenerationSchema(root: DynamicGenerationSchema(name: name, properties: properties), dependencies: [])
        else { return nil }
        return ChatTool(name: name, description: description, parameters: schema, state: state, act: act)
    }

    /// The days left this week that have a session, by name.
    static func sessionDays(_ week: [PlannedWorkout], calendar: Calendar) -> [String: Date] {
        Dictionary(week.map { (dayNames[Week.day(of: $0.date, calendar: calendar)], calendar.startOfDay(for: $0.date)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The weekdays named in what was said, with today and tomorrow as theirs: ["Thursday"].
    static func mentionedDays(_ said: String, now: Date, calendar: Calendar) -> Set<String> {
        let words = said.lowercased().split { !$0.isLetter }.map(String.init)
        var days = Set(dayNames.filter { name in
            let lower = name.lowercased()
            return words.contains { $0 == lower || $0 == lower + "s" || $0 == String(lower.prefix(3)) || (lower == "thursday" && $0 == "thurs") }
        })
        if words.contains("today") || words.contains("tonight") { days.insert(dayNames[Week.day(of: now, calendar: calendar)]) }
        if words.contains("tomorrow") {
            days.insert(dayNames[Week.day(of: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)])
        }
        return days
    }

    static func weekTools(_ state: State) -> [any Tool] {
        let context = state.context
        let calendar = context.calendar
        let week = state.draft.withLock { $0.week } ?? context.week
        let days = sessionDays(week, calendar: calendar)
        guard !days.isEmpty else { return [] }
        let sessionDayNames = dayNames.filter { days[$0] != nil }
        let today = calendar.startOfDay(for: context.now)
        let end = calendar.date(byAdding: .day, value: 7, to: Week.start(of: context.now, calendar: calendar))!
        let openDayNames = dayNames.filter { name in
            let date = Week.date(dayNames.firstIndex(of: name)!, in: Week.start(of: context.now, calendar: calendar), calendar: calendar)
            return date >= today && date < end
        }
        let bySlug = Dictionary(context.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Array(Set(week.filter { $0.note != TrainingGenerator.warmupNote }.map { context.names[$0.exercise] ?? $0.exercise })).sorted()

        /// The week as it stands in the draft, a change made to it, then PlanGuard over the result.
        @Sendable func change(_ draft: inout Draft, line: String, _ rule: (TrainingWeek) -> TrainingWeek?) -> String? {
            let current = TrainingWeek(workouts: draft.week ?? context.week, deload: false, warnings: [])
            guard let changed = rule(current) else { return "That change doesn’t work this week." }
            let guarded = PlanGuard.check(changed.workouts, PlanGuard.Context(settings: context.settings, catalog: context.catalog,
                                                                              names: context.names, history: context.history,
                                                                              light: false, calendar: calendar))
            draft.week = guarded.workouts
            draft.lines.append(line)
            return nil
        }
        // The model picks from the days that have a session, so a day they named that has none comes back as another
        // one ("30 minutes Thursday" shortened Wednesday); code holds it to the days they said.
        let named = mentionedDays(state.said, now: context.now, calendar: calendar)
        @Sendable func day(_ arguments: GeneratedContent, _ property: String) throws -> Date? {
            days[try arguments.value(String.self, forProperty: property)]
        }
        @Sendable func notSaid(_ chosen: String...) -> String? {
            guard !named.isEmpty, named.isDisjoint(with: chosen) else { return nil }
            let list = named.sorted { dayNames.firstIndex(of: $0)! < dayNames.firstIndex(of: $1)! }.joined(separator: " or ")
            let sessions = sessionDayNames.joined(separator: ", ")
            return "There’s no session \(list) this week. Which one do you mean: \(sessions)?"
        }

        return [
            make("move_session", "Move one of this week's sessions to another day this week", [
                choice("day", "The day the session is on now", sessionDayNames),
                choice("to", "The day to move it to", openDayNames),
            ], state) { arguments, draft in
                let toName = try arguments.value(String.self, forProperty: "to")
                if let problem = notSaid(try arguments.value(String.self, forProperty: "day"), toName) { return problem }
                guard let from = try day(arguments, "day") else { return "There’s no session that day." }
                let toDay = Week.date(dayNames.firstIndex(of: toName)!, in: Week.start(of: context.now, calendar: calendar), calendar: calendar)
                // `reschedule` finds the session by its time, and keeps it at that time on the new day.
                let session = (draft.week ?? context.week).first { calendar.isDate($0.date, inSameDayAs: from) }?.date ?? from
                let target = calendar.date(byAdding: calendar.dateComponents([.hour, .minute], from: session), to: toDay) ?? toDay
                let fromName = dayNames[Week.day(of: from, calendar: calendar)]
                guard fromName != toName else { return "It’s already on \(toName)." }
                return change(&draft, line: "\(fromName)’s session moves to \(toName).") { week in
                    TrainingAdjuster.reschedule(week, from: session, to: target) { bySlug[$0]?.pattern }
                }.map { _ in "Moving it there puts the same movement within 48 hours of another session. Another day would work better." }
            },
            make("shorten_session", "Fit one of this week's sessions into less time", [
                choice("day", "The day of the session", sessionDayNames),
                number("minutes", "Minutes they have", 10...120),
            ], state) { arguments, draft in
                if let problem = notSaid(try arguments.value(String.self, forProperty: "day")) { return problem }
                guard let date = try day(arguments, "day") else { return "There's no session that day." }
                let minutes = try arguments.value(Int.self, forProperty: "minutes")
                guard minutes < context.settings.sessionMinutes else { return "That’s not shorter than the \(context.settings.sessionMinutes) minutes planned." }
                return change(&draft, line: "\(dayNames[Week.day(of: date, calendar: calendar)]) fits into \(minutes) minutes.") { week in
                    // `time` matches rows by their exact date; a session's rows share one.
                    let start = week.workouts.first { calendar.isDate($0.date, inSameDayAs: date) }?.date ?? date
                    return TrainingAdjuster.time(week, on: start, minutes: minutes, sessionMinutes: context.settings.sessionMinutes) { $0.main }
                }
            },
            make("lighter_day", "Make one of this week's sessions easier: they're tired, sore or slept badly", [
                choice("day", "The day of the session", sessionDayNames),
            ], state) { arguments, draft in
                if let problem = notSaid(try arguments.value(String.self, forProperty: "day")) { return problem }
                guard let date = try day(arguments, "day") else { return "There's no session that day." }
                return change(&draft, line: "\(dayNames[Week.day(of: date, calendar: calendar)]) goes lighter: fewer sets, easier effort.") { week in
                    let start = week.workouts.first { calendar.isDate($0.date, inSameDayAs: date) }?.date ?? date
                    return TrainingAdjuster.energy(week, on: start)
                }
            },
            make("skip_day", "Take one of this week's sessions out", [
                choice("day", "The day of the session", sessionDayNames),
            ], state) { arguments, draft in
                if let problem = notSaid(try arguments.value(String.self, forProperty: "day")) { return problem }
                guard let date = try day(arguments, "day") else { return "There's no session that day." }
                return change(&draft, line: "No session \(dayNames[Week.day(of: date, calendar: calendar)]).") { week in
                    var week = week
                    week.workouts.removeAll { calendar.isDate($0.date, inSameDayAs: date) }
                    return week
                }
            },
            make("avoid_area", "Work around a body part that hurts for the rest of this week", [
                text("area", "The body part, like shoulder, knee or lower back"),
            ], state) { arguments, draft in
                let area = try arguments.value(String.self, forProperty: "area").lowercased()
                let muscles = BodyArea.muscles(for: [area])
                guard !muscles.isEmpty else { return "Which body part? Like shoulder, knee or lower back." }
                return change(&draft, line: "Exercises that load your \(area) are swapped out this week.") { week in
                    TrainingAdjuster.injury(week, areas: muscles, label: area, settings: context.settings, catalog: context.catalog)
                }
            },
            make("swap_everywhere", "Replace one exercise with another in every session left this week", [
                choice("exercise", "The exercise to replace", names.isEmpty ? ["none"] : names),
                text("replacement", "The exercise to do instead"),
            ], state) { arguments, draft in
                let name = try arguments.value(String.self, forProperty: "exercise")
                guard let old = context.names.first(where: { $0.value == name })?.key ?? bySlug[name]?.slug else { return "That isn’t in this week." }
                let wanted = try arguments.value(String.self, forProperty: "replacement")
                guard let new = PlanGuard.resolve(wanted, in: bySlug, names: context.names)
                        ?? PlanGuard.search(wanted, in: context.catalog, names: context.names, settings: context.settings, limit: 1).first.flatMap({ bySlug[$0] })
                else { return "\(wanted) isn’t an exercise I know. Which one do you mean?" }
                guard TrainingGenerator.allows(new, context.settings) else { return "\(context.names[new.slug] ?? wanted) needs equipment you don’t have, or loads an area you avoid." }
                return change(&draft, line: "\(name) becomes \(context.names[new.slug] ?? wanted) this week.") { week in
                    var week = week
                    week.workouts = week.workouts.compactMap { row in
                        guard row.exercise == old else { return row }
                        // A warm-up for the old lift goes; PlanGuard adds the new one's.
                        guard row.note != TrainingGenerator.warmupNote else { return nil }
                        var dosed = TrainingGenerator.dose(new, main: row.main, sets: Int(row.target("sets") ?? 3), date: row.date,
                                                           session: row.session, settings: context.settings, history: context.history,
                                                           weeksSinceDeload: 0, calendar: calendar).last!
                        dosed.group = row.group
                        dosed.adjustedReason = "instead of \(name)"
                        return dosed
                    }
                    return week
                }
            },
        ].compactMap { $0 }
    }

    static func programTools(_ state: State) -> [any Tool] {
        let context = state.context
        let calendar = context.calendar
        @Sendable func date(_ text: String) -> Date? {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
        }
        @Sendable func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

        return [
            make("set_training_days", "Change which days of the week they train, from now on", [
                .init(name: "days", description: "Every day they'll train",
                      schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "day", anyOf: dayNames), minimumElements: 1, maximumElements: 7)),
            ], state) { arguments, draft in
                let days = Week.ordered(Set(try arguments.value([String].self, forProperty: "days").compactMap { dayNames.firstIndex(of: $0) }))
                guard !days.isEmpty else { return "Which days?" }
                draft.trainingDays = days
                draft.lines.append("Trains \(days.map { String(dayNames[$0].prefix(3)) }.joined(separator: " ")) from now on.")
                return nil
            },
            make("set_session_length", "Change how long every session is, from now on", [
                choice("minutes", "Minutes a session", ["30", "45", "60", "75"]),
            ], state) { arguments, draft in
                guard let minutes = Int(try arguments.value(String.self, forProperty: "minutes")) else { return "How many minutes?" }
                draft.sessionMinutes = minutes
                draft.lines.append("Sessions are \(minutes) minutes from now on.")
                return nil
            },
            make("set_target_date", "Move the program's end date, which is when its goals are due", [
                text("date", "The new end date, as YYYY-MM-DD"),
            ], state) { arguments, draft in
                guard let target = date(try arguments.value(String.self, forProperty: "date")) else { return "What date should it end?" }
                guard let start = context.programStart else { return "There’s no program to change yet." }
                let weeks = ProgramPlan.weekCount(start: start, target: target, calendar: calendar)
                guard target > context.now, OnboardingAnswers.weekRange.contains(weeks) else {
                    return "A program runs \(OnboardingAnswers.weekRange.lowerBound) to \(OnboardingAnswers.weekRange.upperBound) weeks from its start (\(day(start))). Pick a date in that range."
                }
                draft.targetDate = target
                draft.lines.append("The program ends \(day(target)): \(weeks) weeks.")
                return nil
            },
            make("add_trip", "A trip: travel weeks use only dumbbells and bodyweight, and the deload moves into them", [
                text("first_day", "The first day away, as YYYY-MM-DD"),
                text("last_day", "The last day away, as YYYY-MM-DD"),
            ], state) { arguments, draft in
                guard let first = date(try arguments.value(String.self, forProperty: "first_day")),
                      let last = date(try arguments.value(String.self, forProperty: "last_day")), first <= last else {
                    return "What are the first and last days of the trip?"
                }
                guard let start = context.programStart, let program = context.program else { return "There’s no program to change yet." }
                let added = ProgramPlan.travelWeeks(from: first, to: last, start: start, count: program.count,
                                                    trainingDays: draft.trainingDays ?? context.settings.trainingDays)
                guard !added.isEmpty else { return "That trip doesn’t miss a training day in the program." }
                let travel = Set(draft.travelWeeks ?? context.travelWeeks).union(added).sorted()
                draft.travelWeeks = travel
                let numbers = added.sorted().map { $0 + 1 }
                draft.lines.append("\(numbers.count == 1 ? "Week \(numbers[0])" : "Weeks \(numbers.first!)–\(numbers.last!)") (\(day(first))–\(day(last))) are travel weeks: dumbbells and bodyweight.")
                return nil
            },
        ].compactMap { $0 }
    }
}
