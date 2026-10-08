import Foundation

/// FIT-49: today's workout as the workout agent's tools change it. The model only picks a tool and its arguments;
/// every change is made here, and anything new is picked and dosed by the generator's rules.
struct TodayWorkout: Sendable {
    struct Setup: Sendable {
        /// Library slug → name.
        var names: [String: String]
        var catalog: [Exercise]
        var settings: TrainingSettings
        var history: [LoggedSet]
        var weeksSinceDeload: Int
        var date: Date
        var session: String
        var calendar: Calendar = .current
        /// The week's other planned workouts, for the 48-hour rule (FIT-34).
        var planned: [PlannedWorkout] = []
    }

    enum Focus: String, CaseIterable, Sendable {
        case same = "same kind", full = "full body", upper = "upper body", lower = "lower body", push, pull, core

        /// The session's name for this kind of day; nil keeps the one it has.
        var title: String? {
            switch self {
            case .same: nil
            case .full: "Full Body"
            case .upper: "Upper"
            case .lower: "Legs"
            case .push: "Push"
            case .pull: "Pull"
            case .core: "Core"
            }
        }
    }

    enum Equipment: String, CaseIterable, Sendable {
        case all = "everything", dumbbells = "dumbbells only", bodyweight = "bodyweight only", noBarbell = "no barbell"
    }

    let setup: Setup
    private(set) var rows: [PlannedWorkout]
    /// Exercises not in the library, saved with the plan.
    private(set) var newExercises: [TemplateSeed] = []
    /// What changed, for the toast: "Bench Press out".
    private(set) var done: [String] = []
    /// The session's name, the title on Today: a new kind of day renames it ("Pull" made a leg day is "Legs").
    private(set) var session: String

    init(_ today: [PlannedWorkout], setup: Setup) {
        self.setup = setup
        self.rows = today
        self.session = today.first?.session ?? setup.session
    }

    /// "Squats were also yesterday", "Pulling is also tomorrow", "Hinges are also on Friday".
    static func tooSoonText(_ pattern: String, _ date: Date, today: Date, calendar: Calendar) -> String {
        let name = ["squat": "Squats", "lunge": "Lunges", "hinge": "Hinges", "push": "Pushing", "pull": "Pulling",
                    "carry": "Carries", "core": "Core"][pattern] ?? pattern.capitalized
        let plural = !["Pushing", "Pulling", "Core"].contains(name)
        let past = date < calendar.startOfDay(for: today)
        let when = calendar.isDateInYesterday(date) || calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: today)!) ? "yesterday"
            : calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today)!) ? "tomorrow"
            : "on \(date.formatted(.dateTime.weekday(.wide)))"
        let verb = past ? (plural ? "were" : "was") : (plural ? "are" : "is")
        return "\(name) \(verb) also \(when), under 48 h apart"
    }

    /// Today's exercises by name, in order.
    var names: [String] { order(working.map(\.exercise)).map(name) }

    /// A new workout that trains a main movement within 48 h of another session (FIT-34, adjust.md step 3):
    /// "Squats were also yesterday", said with the change, not prevented.
    private(set) var warning: String?

    var summary: String {
        let changes = switch done.count {
        case 0: ""
        case 1, 2: done.joined(separator: ", ")
        default: "\(done[0]) and \(done.count - 1) more changes"
        }
        return [changes, warning].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ". ")
    }

    /// The workout as the model reads it after each tool.
    var text: String {
        guard !working.isEmpty else { return "Nothing planned." }
        return working.map { row in
            var dose = "\(Int(row.target("sets") ?? 1))×"
            if let reps = row.target("reps") { dose += "\(Int(reps))" }
            if let seconds = row.target("duration_s") { dose += "\(Int(seconds)) s" }
            if let meters = row.target("distance_m") { dose += "\(Int(meters)) m" }
            if let pounds = row.target("load_lb") ?? row.target("load_lb_hand") { dose += " at \(Coach.number(pounds)) lb" }
            return "\(name(row.exercise)) \(dose)"
        }.joined(separator: "; ")
    }

    // MARK: Tools

    mutating func remove(_ names: [String]) -> String? {
        let slugs = Set(names.compactMap(todays))
        guard !slugs.isEmpty else { return "None of those are in today's workout." }
        rows.removeAll { slugs.contains($0.exercise) }
        done += order(slugs.sorted()).map { "\(name($0)) out" }
        return nil
    }

    /// The replacement keeps the sets; its reps and weight come from its own history.
    mutating func swap(_ old: String, for new: String, pattern: String? = nil) -> String? {
        guard let slug = todays(old), let index = rows.firstIndex(where: { $0.exercise == slug && working($0) }) else {
            return "\(old) isn't in today's workout."
        }
        let replacement = library(new) ?? seed(new, pattern: pattern ?? movement(of: slug))
        guard let replacement, replacement != slug else { return "Name a different exercise to swap in." }
        let main = rows.contains { $0.exercise == slug && !working($0) }
        let sets = Int(rows[index].target("sets") ?? 3)
        let start = rows.firstIndex { $0.exercise == slug }!
        rows.removeAll { $0.exercise == slug || $0.exercise == replacement }
        rows.insert(contentsOf: dosed(replacement, main: main, sets: sets), at: min(start, rows.count))
        done.append("\(name(replacement)) for \(name(slug))")
        return nil
    }

    mutating func add(_ new: String, pattern: String? = nil, sets: Int? = nil, reps: Int? = nil, seconds: Int? = nil,
                      pounds: Double? = nil) -> String? {
        if let slug = todays(new) {
            return retarget(slug, sets: sets, reps: reps, seconds: seconds, pounds: pounds) ? nil : "\(name(slug)) is already in today's workout."
        }
        guard let slug = library(new) ?? seed(new, pattern: pattern) else { return "Name the exercise to add." }
        rows += dosed(slug, main: false, sets: sets ?? 3)
        _ = retarget(slug, reps: reps, seconds: seconds, pounds: pounds, log: false)
        done.append("\(name(slug)) added")
        return nil
    }

    /// nil `exercise` is every exercise. `more` adds sets to what's planned.
    mutating func change(_ exercise: String?, sets: Int? = nil, more: Int? = nil, reps: Int? = nil, seconds: Int? = nil,
                         pounds: Double? = nil) -> String? {
        let slugs: [String]
        if let exercise {
            guard let slug = todays(exercise) else { return "\(exercise) isn't in today's workout." }
            slugs = [slug]
        } else {
            slugs = order(working.map(\.exercise))
        }
        var changed = false
        for slug in slugs {
            let planned = working.first { $0.exercise == slug }.flatMap { $0.target("sets") }.map(Int.init) ?? 3
            changed = retarget(slug, sets: sets ?? more.map { planned + $0 }, reps: reps, seconds: seconds,
                               pounds: exercise == nil ? nil : pounds, log: exercise != nil) || changed
        }
        if exercise == nil, changed { done.append(sets.map { "Every exercise \($0) sets" } ?? "Every exercise changed") }
        return changed ? nil : "Nothing changed: they didn’t say a new number. For a different exercise, use swap_exercise."
    }

    /// The workout becomes exactly these, in this order: today's keep their numbers, the rest are added.
    mutating func keepOnly(_ names: [String]) -> String? {
        var kept: [PlannedWorkout] = [], added: [String] = []
        for wanted in names {
            if let slug = todays(wanted) {
                if !kept.contains(where: { $0.exercise == slug }) { kept += rows.filter { $0.exercise == slug } }
            } else if let slug = library(wanted) ?? seed(wanted, pattern: nil), !kept.contains(where: { $0.exercise == slug }) {
                kept += dosed(slug, main: false, sets: 3)
                added.append(slug)
            }
        }
        guard kept.contains(where: working) else { return "Name exercises for the workout." }
        rows = kept
        done.append("Just " + order(kept.map(\.exercise)).map(name).joined(separator: " and "))
        return nil
    }

    /// Harder: a set more of everything, main lifts 5 lb heavier. Easier: a set less and 10% lighter.
    mutating func effort(harder: Bool) -> String? {
        guard !working.isEmpty else { return "Nothing planned to change." }
        rows = rows.map { row in
            guard working(row) else { return row }
            var item = WorkoutEdit.items([row], names: [:])[0]
            item.sets = min(max(item.sets + (harder ? 1 : -1), 1), 10)
            item.pounds = item.pounds.map { harder ? $0 + (row.target("load_lb") != nil ? 5 : 0) : TrainingGenerator.roundTo5($0 * 0.9) }
            return WorkoutEdit.changed(row, to: item)
        }
        done.append(harder ? "Harder" : "Easier")
        return nil
    }

    /// A whole new session, by the generator's rules, preferring exercises that aren't in today's.
    mutating func regenerate(_ focus: Focus, equipment: Equipment = .all, skip patterns: Set<String> = [],
                             minutes: Int? = nil) -> String? {
        var settings = setup.settings
        switch equipment {
        case .all: break
        case .dumbbells: settings.equipment.formIntersection(["dumbbells"])
        case .bodyweight: settings.equipment = []
        case .noBarbell: settings.equipment.subtract(["barbell", "rack"])
        }
        let slots = slots(for: focus).filter { !patterns.contains($0.pattern) }
        // The same kind of day, or only less equipment or time, keeps its name.
        let title = focus.title ?? session
        let session = TrainingGenerator.session(on: setup.date, slots: slots, name: title,
                                                avoiding: Set(rows.map(\.exercise)), minutes: minutes, settings: settings,
                                                catalog: setup.catalog, history: setup.history,
                                                weeksSinceDeload: setup.weeksSinceDeload, calendar: setup.calendar)
        guard !session.isEmpty else { return "No exercises in the library fit that." }
        rows = session
        self.session = title
        warning = TrainingAdjuster.tooSoon(rows, on: setup.date, history: setup.history,
                                           planned: setup.planned.filter { !setup.calendar.isDate($0.date, inSameDayAs: setup.date) },
                                           patternOf: { slug in setup.catalog.first { $0.slug == slug }?.pattern }, calendar: setup.calendar)
            .map { Self.tooSoonText($0.pattern, $0.date, today: setup.date, calendar: setup.calendar) }
        newExercises = []
        let summary = switch focus {
        case .same, .full: "New workout"
        case .upper: "New upper body workout"
        case .lower: "New leg workout"
        default: "New \(focus.rawValue) workout"
        }
        done.append(summary)
        return nil
    }

    // MARK: Helpers

    private var working: [PlannedWorkout] { rows.filter(working) }

    private func working(_ row: PlannedWorkout) -> Bool { row.note != TrainingGenerator.warmupNote }

    private func order(_ slugs: [String]) -> [String] { slugs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    func name(_ slug: String) -> String {
        setup.names[slug] ?? newExercises.first { $0.slug == slug }?.name ?? slug
    }

    /// Which of today's exercises a name means.
    private func todays(_ said: String) -> String? {
        let slugs = order(working.map(\.exercise))
        let wanted = Slug.make(said)
        return slugs.first { $0 == wanted || Slug.make(name($0)) == wanted }
            ?? slugs.first { WorkoutEdit.same(said, name($0)) }
            ?? WorkoutEdit.find(said, in: setup.names).flatMap { slugs.contains($0) ? $0 : nil }
    }

    /// The library exercise a name means: first among what the user can do (their equipment, no injury, not
    /// avoided), the author's cards, then the well-known staples (FIT-70), so "dips" is Bench Dips rather than Ring
    /// Dips; then the whole library.
    private func library(_ said: String) -> String? {
        let doable = Set(setup.catalog.filter { TrainingGenerator.allows($0, setup.settings) }.map(\.slug))
        let rank = Dictionary(setup.catalog.map { ($0.slug, $0.isCurated ? 0 : $0.tags.contains("staple") ? 1 : 2) },
                              uniquingKeysWith: { first, _ in first })
        return WorkoutEdit.find(said, in: setup.names.filter { doable.contains($0.key) }, rank: rank)
            ?? WorkoutEdit.find(said, in: setup.names, rank: rank)
    }

    /// An exercise that isn't in the library, saved with the plan.
    private mutating func seed(_ said: String, pattern: String?) -> String? {
        let name = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Slug.make(name)
        guard !slug.isEmpty else { return nil }
        if !newExercises.contains(where: { $0.slug == slug }) {
            let pattern = pattern.flatMap { WorkoutEdit.patterns.contains($0) ? $0 : nil } ?? "core"
            newExercises.append(TemplateSeed(kind: .exercise, name: name.capitalized, slug: slug,
                                             attributes: [TemplateAttribute(key: "movement_pattern", values: [pattern])]))
        }
        return slug
    }

    private func movement(of slug: String) -> String? {
        setup.catalog.first { $0.slug == slug }?.pattern
            ?? newExercises.first { $0.slug == slug }.flatMap { Exercise(slug: $0.slug, attributes: $0.attributes)?.pattern }
    }

    private func dosed(_ slug: String, main: Bool, sets: Int) -> [PlannedWorkout] {
        if let exercise = setup.catalog.first(where: { $0.slug == slug }) {
            return TrainingGenerator.dose(exercise, main: main, sets: sets, date: setup.date, session: session,
                                          settings: setup.settings, history: setup.history,
                                          weeksSinceDeload: setup.weeksSinceDeload, calendar: setup.calendar)
                .map { var row = $0; row.adjustedReason = "asked for"; return row }
        }
        return [PlannedWorkout(date: setup.date, session: session, exercise: slug, targets: [
            Measurement(metric: "sets", value: Double(sets), unit: "sets"),
            Measurement(metric: "reps", value: setup.settings.style.reps.accessory, unit: "reps"),
        ], adjustedReason: "asked for")]
    }

    /// New numbers for an exercise's working rows; what isn't given stays. A hold given reps gets them as seconds.
    @discardableResult
    private mutating func retarget(_ slug: String, sets: Int? = nil, reps: Int? = nil, seconds: Int? = nil,
                                   pounds: Double? = nil, log: Bool = true) -> Bool {
        var changed = false
        for index in rows.indices where rows[index].exercise == slug && working(rows[index]) {
            let row = rows[index]
            var item = WorkoutEdit.items([row], names: [:])[0]
            let timed = row.target("duration_s") != nil
            if let sets, (1...10).contains(sets) { item.sets = sets }
            if let seconds = seconds ?? (timed ? reps : nil), (5...600).contains(seconds) { (item.seconds, item.reps) = (seconds, nil) }
            else if let reps, (1...50).contains(reps), !timed { item.reps = reps }
            if let pounds, pounds > 0, pounds <= 1500 { item.pounds = pounds }
            guard item != WorkoutEdit.items([row], names: [:])[0] else { continue }
            rows[index] = WorkoutEdit.changed(row, to: item)
            changed = true
        }
        if changed && log {
            let row = working.first { $0.exercise == slug }!
            var dose = "\(Int(row.target("sets") ?? 1))×"
            dose += row.target("duration_s").map { "\(Int($0)) s" } ?? row.target("reps").map { "\(Int($0))" } ?? ""
            if let pounds = row.target("load_lb") ?? row.target("load_lb_hand") { dose += " at \(Coach.number(pounds))" }
            done.append("\(name(slug)) \(dose)")
        }
        return changed
    }

    private func slots(for focus: Focus) -> [Slot] {
        func s(_ slots: (String, Bool)...) -> [Slot] { slots.map { Slot(pattern: $0.0, main: $0.1) } }
        switch focus {
        case .same:
            let today = order(working.map(\.exercise))
            guard !today.isEmpty else { return slots(for: .full) }
            return today.compactMap { slug in
                movement(of: slug).map { Slot(pattern: $0, main: rows.contains { $0.exercise == slug && !working($0) }) }
            }
        case .full: return s(("squat", true), ("push", true), ("hinge", false), ("pull", false), ("core", false))
        case .upper: return s(("push", true), ("pull", true), ("push", false), ("pull", false), ("core", false))
        case .lower: return s(("squat", true), ("hinge", false), ("squat", false), ("carry", false), ("core", false))
        case .push: return s(("push", true), ("push", false), ("push", false), ("core", false))
        case .pull: return s(("pull", true), ("pull", false), ("pull", false), ("carry", false))
        case .core: return s(("core", false), ("core", false), ("carry", false))
        }
    }
}
