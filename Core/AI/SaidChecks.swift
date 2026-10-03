import Foundation

/// FIT-51: what a spoken edit's words rule out, checked in code. The on-device model keeps picking the wrong tool for
/// these (a new workout when exercises were named, a leg day for "nothing for legs"), so the agent's tools use these to
/// refuse the call with a reason, or to fix it.
enum SaidChecks {
    /// Lowercase words only, padded with spaces so " split squat " matches whole words: "Give me squats!" → " give me squats ".
    static func words(_ text: String) -> String {
        " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }

    /// The library exercises named in full, plural or not: "squats and split squat" names Split Squat.
    static func named(in said: String, library: some Sequence<String>) -> [String] {
        let said = words(said)
        return library.filter { name in
            let base = name.split(separator: "(").first.map(String.init) ?? name
            let words = words(base).trimmingCharacters(in: .whitespaces)
            return !words.isEmpty && (said.contains(" \(words) ") || said.contains(" \(words)s "))
        }
    }

    /// A new workout is asked for by its kind, equipment or length ("make it a leg day", "dumbbells only", "30 minutes"),
    /// never by listing exercises: "give me squats and split squat" has none of these.
    static func asksForAWorkout(_ said: String) -> Bool {
        let cues: Set<String> = ["workout", "day", "session", "regenerate", "again", "mix", "different", "new", "plan", "body",
                                 "leg", "legs", "lower", "upper", "dumbbell", "dumbbells", "bodyweight",
                                 "barbell", "equipment", "minute", "minutes", "min", "hour", "quick", "short"]
        return !cues.isDisjoint(with: words(said).split(separator: " ").map(String.init))
    }

    /// They meant the whole workout: "make everything 4 sets", "every exercise", "all".
    static func meansEvery(_ said: String) -> Bool {
        let said = words(said)
        return [" every ", " all ", " everything ", " each ", " whole "].contains { said.contains($0) }
    }

    /// "just bench and plank", "only pull-ups": the workout becomes these.
    static func meansJustThese(_ said: String) -> Bool {
        let said = words(said)
        return said.hasPrefix(" just ") || said.hasPrefix(" only ")
    }

    /// "nothing for legs", "no lower body today", "skip legs": the negation sits right in front of legs, so
    /// "no bench today, legs instead" doesn't count.
    static func rulesOutLegs(_ said: String) -> Bool {
        words(said).contains(#/\s(no|nothing|skip|without|not|never)\s(?:(?:for|on|the|any|my|more|work|of)\s){0,3}(?:legs?|lower)\s/#)
    }

    /// FIT-51: the tools a request needs. Every tool the model is given costs about 0.4 s before it starts (7 tools: 5.7 s,
    /// the one it needs: 1.5 s), so it gets only those the words point at, and all of them when nothing does. The agent
    /// falls back to all of them when these make no change.
    static func tools(for said: String, today hasToday: Bool) -> [String] {
        let spoken = Set(words(said).split(separator: " ").map(String.init))
        func has(_ cues: String...) -> Bool { cues.contains { spoken.contains($0) } }
        let numbers = !SpokenNumbers.values(in: said).isEmpty
        // "Nothing for legs" asks for a different workout, not for exercises to come out.
        if rulesOutLegs(said) { return ["new_workout"] }
        var tools: [String] = []
        if hasToday {
            if has("no", "skip", "drop", "remove", "without", "cut", "delete", "ditch", "lose") { tools.append("remove_exercises") }
            if has("swap", "instead", "replace", "switch", "rather") { tools.append("swap_exercise") }
            if numbers || has("set", "sets", "rep", "reps", "pound", "pounds", "lb", "lbs", "second", "seconds", "minute", "minutes",
                              "heavier", "lighter", "bump", "everything", "every", "all") || words(said).contains(" a set ") {
                tools.append("change_exercise")
            }
            if has("harder", "easier", "tougher", "hard", "easy", "intense", "lighter") { tools.append("harder_or_easier") }
        }
        if has("add", "also", "include", "plus", "another", "throw", "tack", "want") || numbers { tools.append("add_exercise") }
        if has("just", "only", "want", "give", "let's", "lets") { tools.append("only_these") }
        if asksForAWorkout(said) { tools.append("new_workout") }
        return tools.isEmpty ? all(hasToday) : tools
    }

    /// Every tool, for a request the words don't point at and for the fallback.
    static func all(_ hasToday: Bool) -> [String] {
        (hasToday ? ["remove_exercises", "swap_exercise", "change_exercise", "harder_or_easier"] : [])
            + ["add_exercise", "only_these", "new_workout"]
    }
}
