import Foundation

/// FIT-47: today's workout as the model sees it, and the model's edited copy checked and turned back into plan rows.
/// The model isn't expected to be deterministic; this only makes sure what it returns is something the plan can hold.
enum WorkoutEdit {
    static let patterns = ["squat", "hinge", "push", "pull", "carry", "core"]

    /// One exercise as the model reads and writes it.
    struct Item: Codable, Equatable, Sendable {
        var name: String
        var sets: Int
        var reps: Int?
        var seconds: Int?
        var pounds: Double?
        /// Only read for an exercise that isn't in the library.
        var pattern: String? = nil
    }

    struct Result: Equatable {
        var workouts: [PlannedWorkout]
        /// Exercises the model named that aren't in the library, saved with the plan.
        var newExercises: [TemplateSeed]
    }

    /// Today's working sets, warm-ups left out, one item per row.
    static func items(_ today: [PlannedWorkout], names: [String: String]) -> [Item] {
        today.filter(working).map { row in
            Item(name: names[row.exercise] ?? row.exercise, sets: Int(row.target("sets") ?? 1),
                 reps: row.target("reps").map { Int($0) }, seconds: row.target("duration_s").map { Int($0) },
                 pounds: row.target("load_lb") ?? row.target("load_lb_hand"))
        }
    }

    static func json(_ items: [Item]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The edited workout as plan rows. An exercise left exactly as it was keeps its rows (warm-up, effort cap,
    /// superset); a changed one keeps its other targets and any number the model left out; a name that isn't in the
    /// library becomes a new exercise.
    /// Numbers outside what a person could do are dropped. nil when nothing usable came back.
    static func apply(_ edited: [Item], to today: [PlannedWorkout], library: [String: String], date: Date,
                      session: String) -> Result? {
        var bySlug: [String: String] = [:]
        for (slug, name) in library {
            bySlug[key(slug)] = slug
            bySlug[key(Slug.make(name))] = slug
        }
        var rows: [PlannedWorkout] = [], seeds: [TemplateSeed] = []
        var used = Set<Int>()
        for item in edited {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var slug = bySlug[key(Slug.make(name))] ?? closest(name, library: library, taken: Set(rows.map(\.exercise)))
            if slug == nil {
                let new = Slug.make(name)
                guard !new.isEmpty else { continue }
                if !seeds.contains(where: { $0.slug == new }) {
                    let pattern = item.pattern.flatMap { patterns.contains($0) ? $0 : nil } ?? "core"
                    seeds.append(TemplateSeed(kind: .exercise, name: name, slug: new,
                                              attributes: [TemplateAttribute(key: "movement_pattern", values: [pattern])]))
                }
                slug = new
            }
            guard let slug else { continue }
            // The same new exercise twice in a row ("Curl", "Curl") is one exercise with both sets.
            if let last = rows.last, last.exercise == slug, !today.contains(where: { $0.exercise == slug }) {
                rows[rows.count - 1].targets = last.targets.map {
                    $0.metric == "sets" ? Measurement(metric: "sets", value: min($0.value + Double(item.sets), 10), unit: "sets") : $0
                }
                continue
            }
            let clean = Item(name: name, sets: min(max(item.sets, 1), 10),
                             reps: item.reps.flatMap { (1...50).contains($0) ? $0 : nil },
                             seconds: item.seconds.flatMap { (5...600).contains($0) ? $0 : nil },
                             pounds: item.pounds.flatMap { $0 > 0 && $0 <= 1500 ? $0 : nil })
            // The first of today's rows for this exercise not yet used, with its warm-up.
            if let index = today.indices.first(where: { !used.contains($0) && working(today[$0]) && today[$0].exercise == slug }) {
                used.insert(index)
                if !rows.contains(where: { $0.exercise == slug }) {
                    rows += today.filter { !working($0) && $0.exercise == slug }
                }
                let old = today[index]
                // The model often leaves numbers out of exercises it didn't touch: what it omits stays as planned.
                var kept = clean
                if old.target("duration_s") != nil, kept.seconds == nil, let reps = kept.reps { (kept.seconds, kept.reps) = (reps, nil) }
                if kept.reps == nil && kept.seconds == nil {
                    kept.reps = old.target("reps").map { Int($0) }
                    kept.seconds = old.target("duration_s").map { Int($0) }
                }
                kept.pounds = kept.pounds ?? old.target("load_lb") ?? old.target("load_lb_hand")
                rows.append(same(old, kept) ? old : changed(old, to: kept))
            } else {
                rows.append(changed(PlannedWorkout(date: date, session: session, exercise: slug, targets: []), to: clean))
            }
        }
        guard rows.contains(where: working) else { return nil }
        return Result(workouts: rows, newExercises: seeds.filter { seed in rows.contains { $0.exercise == seed.slug } })
    }

    /// A shortened library name ("Squat", "Romanian Deadlift"): the library exercise with all its words and the
    /// fewest others, preferring one not already in the workout.
    private static func closest(_ name: String, library: [String: String], taken: Set<String>) -> String? {
        let words = Set(key(Slug.make(name)).split(separator: "-"))
        return library.filter { words.isSubset(of: Set(key(Slug.make($0.value)).split(separator: "-"))) }
            .min { a, b in
                let order = { (slug: String, name: String) in (taken.contains(slug) ? 1 : 0, Slug.make(name).count, slug) }
                return order(a.key, a.value) < order(b.key, b.value)
            }?.key
    }

    private static func working(_ row: PlannedWorkout) -> Bool { row.note != TrainingGenerator.warmupNote }

    private static func same(_ row: PlannedWorkout, _ item: Item) -> Bool {
        Int(row.target("sets") ?? 1) == item.sets && row.target("reps").map { Int($0) } == item.reps
            && row.target("duration_s").map { Int($0) } == item.seconds
            && (row.target("load_lb") ?? row.target("load_lb_hand")) == item.pounds
    }

    private static func changed(_ row: PlannedWorkout, to item: Item) -> PlannedWorkout {
        var row = row
        let perHand = row.target("load_lb_hand") != nil
        let replaced: Set<String> = ["sets", "reps", "duration_s", "load_lb", "load_lb_hand"]
        row.targets = [Measurement(metric: "sets", value: Double(item.sets), unit: "sets")]
            + (item.reps.map { [Measurement(metric: "reps", value: Double($0), unit: "reps")] } ?? [])
            + (item.seconds.map { [Measurement(metric: "duration_s", value: Double($0), unit: "s")] } ?? [])
            + (item.pounds.map { [Measurement(metric: perHand ? "load_lb_hand" : "load_lb", value: $0, unit: "lb")] } ?? [])
            + row.targets.filter { !replaced.contains($0.metric) }
        row.adjustedReason = "asked for"
        return row
    }

    /// "Back Squats" finds back-squat.
    private static func key(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : String($0) }
            .joined(separator: "-")
    }
}
