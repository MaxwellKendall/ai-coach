import Foundation

/// FIT-70: the exercise catalog from free-exercise-db (public domain, github.com/yuhonas/free-exercise-db), as
/// catalog seeds with the attributes the generators read. The author's fitness-planner cards win: an entry that's
/// the same exercise adds its name as an alias and fills only the keys the card lacks.
enum ExerciseDBImporter {
    struct Entry: Decodable {
        var name: String
        var force: String?
        var level: String?
        var mechanic: String?
        var equipment: String?
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
        var category: String
        /// Step-by-step how-to (FIT-75).
        var instructions: [String]? = nil
    }

    struct Import {
        var seeds: [TemplateSeed]
        /// "Atlas Stones: strongman equipment".
        var skipped: [String]
    }

    /// free-exercise-db names that are the author's cards.
    static let aliases = [
        "Barbell Squat": "back-squat", "Barbell Bench Press - Medium Grip": "bench-press", "Barbell Deadlift": "deadlift",
        "Dumbbell Bench Press": "dumbbell-bench-press", "One-Arm Dumbbell Row": "dumbbell-row", "Farmer's Walk": "farmer-carry",
        "Goblet Squat": "goblet-squat", "Plank": "plank", "Pullups": "pull-up", "Pushups": "push-up", "Dead Bug": "dead-bug",
    ]

    /// The well-known lifts a coach reaches for first (general practice), so search lists them before variations:
    /// FIT-72's model takes what's listed first, and "Iron Cross" came before "Barbell Shoulder Press".
    static let staples: Set<String> = [
        "Romanian Deadlift", "Sumo Deadlift", "Trap Bar Deadlift", "Front Squat (Clean Grip)", "Barbell Hip Thrust",
        "Barbell Glute Bridge", "Good Morning", "Leg Press", "Hack Squat", "Leg Extensions", "Lying Leg Curls",
        "Seated Leg Curl", "Barbell Lunge", "Dumbbell Lunges", "Bodyweight Walking Lunge", "Split Squat with Dumbbells",
        "Dumbbell Step Ups", "Standing Calf Raises", "Seated Calf Raise", "Barbell Shoulder Press", "Standing Military Press",
        "Dumbbell Shoulder Press", "Arnold Dumbbell Press", "Push Press", "Barbell Incline Bench Press - Medium Grip",
        "Incline Dumbbell Press", "Dumbbell Flyes", "Dips - Chest Version", "Dips - Triceps Version", "Bent Over Barbell Row",
        "Seated Cable Rows", "T-Bar Row with Handle", "Inverted Row", "Chin-Up", "Wide-Grip Lat Pulldown", "Face Pull",
        "Reverse Flyes", "Side Lateral Raise", "Barbell Shrug", "Dumbbell Shrug", "Barbell Curl", "Dumbbell Bicep Curl",
        "Hammer Curls", "EZ-Bar Curl", "Triceps Pushdown", "EZ-Bar Skullcrusher", "Lying Triceps Press", "Hanging Leg Raise",
        "Crunches", "Russian Twist", "Pallof Press", "Mountain Climbers", "Hyperextensions (Back Extensions)",
        "One-Arm Kettlebell Swings", "Rowing, Stationary", "Rope Jumping", "Bicycling, Stationary", "Running, Treadmill",
        "Walking, Treadmill", "Elliptical Trainer", "Box Jump (Multiple Response)", "Power Clean", "Bodyweight Squat",
        "Dumbbell Squat", "Side Bridge", "Bench Dips", "Band Pull Apart", "Glute Ham Raise", "Kettlebell Goblet Squat",
    ]

    static func seeds(json: Data, merging cards: [TemplateSeed]) throws -> Import {
        let entries = try JSONDecoder().decode([Entry].self, from: json)
        var seeds = cards
        var skipped: [String] = []
        var slugs = Set(cards.map(\.slug))
        for entry in entries {
            if let slug = aliases[entry.name], let index = seeds.firstIndex(where: { $0.slug == slug }) {
                guard case .success(let seed) = seed(entry) else { continue }
                seeds[index] = merged(seeds[index], with: seed, alias: entry.name)
                continue
            }
            switch seed(entry) {
            case .success(var seed):
                seed.slug = Slug.unique(seed.name, existing: slugs)
                slugs.insert(seed.slug)
                seeds.append(seed)
            case .failure(let reason):
                skipped.append("\(entry.name): \(reason.text)")
            }
        }
        return Import(seeds: seeds, skipped: skipped)
    }

    struct Skip: Error { var text: String }

    /// Whether a name has any of these words or phrases at a word's start: "chin" matches "Chin-Up" and "Chins"
    /// but not "Machine".
    static func matcher(_ name: String) -> (String...) -> Bool {
        func words(_ text: String) -> String {
            " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let name = words(name)
        return { phrases in phrases.contains { name.contains(words($0)) } }
    }

    static func seed(_ entry: Entry) -> Swift.Result<TemplateSeed, Skip> {
        let has = matcher(entry.name)
        if ["stretching"].contains(entry.category) || entry.equipment == "foam roll" { return .failure(Skip(text: "a stretch")) }
        if entry.category == "strongman" || dropped.contains(where: { has($0) }) {
            return .failure(Skip(text: "strongman, partner or specialty equipment"))
        }
        // General practice: behind-the-neck pressing and pulling loads the shoulder at end range.
        if has("behind the neck", "behind neck") { return .failure(Skip(text: "behind the neck")) }
        guard let equipment = equipment(entry) else { return .failure(Skip(text: "equipment unknown")) }
        guard let pattern = pattern(entry) else { return .failure(Skip(text: "no movement pattern (\(entry.primaryMuscles.joined(separator: ", ")))")) }
        let compound = entry.mechanic == "compound" || (entry.mechanic == nil && pattern != "arms")
        var tags = [compound ? "compound" : "isolation"]
        if let plane = plane(entry, pattern: pattern) { tags.append(plane) }
        if staples.contains(entry.name) { tags.append("staple") }
        if entry.force == "static" && (pattern == "core" || has("plank", "hold", "hang", "wall sit")) {
            tags.append("isometric")
        } else if entry.category == "cardio" || equipment.contains("jump_rope") {
            tags.append("timed")
        }
        var attributes = [
            TemplateAttribute(key: "movement_pattern", values: [pattern]),
            TemplateAttribute(key: "equipment", values: equipment.sorted()),
            TemplateAttribute(key: "muscles_primary", values: muscles(entry.primaryMuscles)),
            TemplateAttribute(key: "muscles_secondary", values: muscles(entry.secondaryMuscles)),
            TemplateAttribute(key: "fatigue_cost", values: [String(fatigue(compound: compound, pattern: pattern, equipment: equipment))]),
            TemplateAttribute(key: "tags", values: tags),
            TemplateAttribute(key: "source", values: ["free-exercise-db"]),
        ]
        if let level = entry.level { attributes.append(TemplateAttribute(key: "level", values: [level])) }
        if let steps = entry.instructions, !steps.isEmpty { attributes.append(TemplateAttribute(key: "instructions", values: steps)) }
        return .success(TemplateSeed(kind: .exercise, name: entry.name, slug: Slug.make(entry.name),
                                     attributes: attributes.filter { !$0.values.isEmpty }))
    }

    // MARK: Equipment

    /// Strongman implements, partner work, drills and other gear nobody lists as equipment.
    static let dropped = ["atlas", "keg", "log lift", "yoke", "conan", "circus", "rickshaw", "car deadlift", "tire",
                          "sandbag", "chain", "axle", "sledgehammer", "heavy bag", "balance board", "ab roller",
                          "wrist roller", "london bridge", "power stairs", "crucifix", "manual", "battling ropes",
                          "rope climb", "drill", "technique", "series", "partner", "hamstring slides", "donkey calf"]

    /// The equipment an exercise needs, in Profile.allEquipment's vocabulary. Body-weight exercises still need the
    /// bar, bench or box they're done on; free weights need a bench when they're done seated, lying or inclined.
    static func equipment(_ entry: Entry) -> Set<String>? {
        let has = matcher(entry.name)
        var needs: Set<String>
        switch entry.equipment {
        case "barbell": needs = ["barbell"]
        case "dumbbell": needs = ["dumbbells"]
        case "kettlebells": needs = ["kettlebells"]
        case "cable": needs = ["cable"]
        case "machine": needs = has("treadmill") ? ["treadmill"] : has("rowing") ? ["rower"] : has("bicycl", "bike", "cycling") ? ["bike"] : ["machine"]
        case "bands": needs = ["bands"]
        case "medicine ball": needs = ["medicine_ball"]
        case "exercise ball": needs = ["exercise_ball"]
        case "e-z curl bar": needs = ["ez_bar"]
        case "body only", nil: needs = []
        case "other":
            if has("trap bar") { needs = ["trap_bar"] }
            else if has("sled", "prowler") { needs = ["sled"] }
            else if has("suspended", "straps", "ring") { needs = ["suspension"] }
            else if has("plate", "otis") { needs = ["barbell"] }
            else if has("bicycl", "bike") { needs = ["bike"] }
            else if has("rope jumping") { needs = ["jump_rope"] }
            else if has("hyperextension") { needs = ["machine"] }
            else if has("band") { needs = ["bands"] }
            else if has("pull-up", "pullup", "pull up", "pull ups", "chin", "muscle up", "dip", "parallel bar", "box", "bench", "hop", "jump", "leap", "skip", "sprint", "skating", "push", "squat", "hurdle", "cone", "stride", "bound") { needs = [] }
            else { return nil }
        default: return nil
        }
        if has("pull-up", "pullup", "pull up", "pull ups", "chin-up", "chin up", "chins", " chin", "muscle up", "hanging", "toes to bar") { needs.insert("pull_up_bar") }
        if has("dip", "parallel bar"), !has("bench dip"), !needs.contains("suspension") { needs.insert("dip_station") }
        if has("box") { needs.insert("box") }
        let freeWeight = !needs.isDisjoint(with: ["barbell", "dumbbells", "kettlebells", "ez_bar"])
        if has("bench") || (freeWeight && has("seated", "lying", "incline", "decline", "preacher")) { needs.insert("bench") }
        if needs.contains("barbell"), has("squat", "bench press", "military press", "overhead press", "shoulder press"),
           !has("front squat to a bench", "jump", "overhead squat") { needs.insert("rack") }
        if entry.name == "Inverted Row" { needs = ["barbell", "rack"] }
        return needs
    }

    // MARK: Movement

    static func pattern(_ entry: Entry) -> String? {
        let has = matcher(entry.name)
        if ["cardio", "plyometrics"].contains(entry.category) { return "conditioning" }
        if entry.category == "olympic weightlifting" { return "olympic" }
        if has("carry", "farmer", "walk"), !has("lunge") { return "carry" }
        // By name before muscle: free-exercise-db lists the trap bar deadlift as quads.
        if has("deadlift", "good morning", "hip thrust", "swing"), entry.mechanic != "isolation" { return "hinge" }
        let isolation = entry.mechanic == "isolation"
        switch entry.primaryMuscles.first {
        case "abdominals": return "core"
        case "calves": return "calves"
        case "quadriceps":
            if has("lunge", "split squat", "step-up", "step up", "bulgarian") { return "lunge" }
            return isolation ? "legs" : "squat"
        case "hamstrings": return isolation || has("curl") ? "legs" : "hinge"
        case "glutes": return isolation ? "legs" : "hinge"
        case "lower back": return "hinge"
        case "adductors", "abductors": return "legs"
        case "chest": return "push"
        case "shoulders": return entry.force == "push" && !isolation || has("press", "push") ? "push" : "shoulders"
        case "triceps": return isolation ? "arms" : "push"
        case "biceps", "forearms": return "arms"
        case "lats", "middle back", "traps": return "pull"
        default: return nil
        }
    }

    /// Pushes and pulls are horizontal or vertical, by the tags the fitness-planner cards use.
    static func plane(_ entry: Entry, pattern: String) -> String? {
        let has = matcher(entry.name)
        switch pattern {
        case "push": return entry.primaryMuscles.first == "shoulders" || has("overhead", "military", "handstand", "pike")
            ? "vertical_push" : "horizontal_push"
        case "pull": return has("pull-up", "pullup", "pull up", "chin", "pulldown", "pull-down", "pullover", "muscle up")
            ? "vertical_pull" : "horizontal_pull"
        default: return nil
        }
    }

    /// free-exercise-db's muscles as the names the cards and BodyArea use.
    static func muscles(_ names: [String]) -> [String] {
        let map = ["quadriceps": "quads", "chest": "pectorals", "shoulders": "deltoids", "middle back": "rhomboids",
                   "lower back": "spinal_erectors", "abdominals": "rectus_abdominis"]
        return names.map { map[$0] ?? $0.replacingOccurrences(of: " ", with: "_") }
    }

    /// The cards' 1–5 fatigue cost, from what the exercise is: heavy barbell lower-body work costs most, isolation least.
    static func fatigue(compound: Bool, pattern: String, equipment: Set<String>) -> Int {
        guard compound else { return 1 }
        if pattern == "conditioning" { return 2 }
        let barbell = !equipment.isDisjoint(with: ["barbell", "trap_bar"])
        if barbell { return ["squat", "hinge", "lunge", "olympic"].contains(pattern) ? 5 : 4 }
        return equipment.isDisjoint(with: ["dumbbells", "kettlebells", "cable", "machine", "ez_bar", "sled", "medicine_ball"]) ? 2 : 3
    }

    /// A card keeps everything it has; the entry adds its name as an alias and any key the card lacks.
    static func merged(_ card: TemplateSeed, with seed: TemplateSeed, alias: String) -> TemplateSeed {
        var card = card
        let keys = Set(card.attributes.map(\.key))
        card.attributes += seed.attributes.filter { !keys.contains($0.key) && $0.key != "source" }
        card.attributes.append(TemplateAttribute(key: "aliases", values: [alias]))
        return card
    }
}
