import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func html(_ id: String, _ json: String) -> String {
    "<html><body><h1>Log</h1><script type=\"application/json\" id=\"\(id)\">\(json)</script></body></html>"
}

struct HistoryImporterTests {
    @Test func sessionExpandsSetsAndHandlesLoadAndRepsQuirks() {
        let result = HistoryImporter.session(html: html("session-data", """
            { "date": "2026-06-19", "session_label": "Session A", "completed": true, "reconstructed": true,
              "exercises": [
                { "slug": "back-squat", "sets": 3, "reps": 5, "load_lb": 165, "rpe": 7 },
                { "slug": "pull-up", "sets": 4, "reps": "5,5,5,3", "load": "BW", "rpe": 7 },
                { "slug": "db-row", "sets": 2, "reps": 10, "load": "95 lb" },
                { "slug": "farmer-carry", "sets": 3, "reps": "30m", "load": "24 kg/hand" },
                { "slug": "plank", "sets": 3, "reps": "50s", "load": "BW" },
                { "slug": "dumbbell-row", "sets": 2, "reps": 8, "load_lb_hand": 24 },
                { "slug": "dead-bug", "sets": 0, "skipped": true },
                { "slug": "barbell-row", "sets": null, "reps": null, "load_lb": 95 },
                { "slug": "back-squat", "sets": 1, "reps": 5, "load_lb": 95, "note": "warm-up" }
              ] }
            """), fileName: "2026-06-19.html", calendar: calendar)

        let bySlug = Dictionary(grouping: result.entries, by: { $0.template ?? "" })
        #expect(bySlug["back-squat"]?.count == 3)
        #expect(bySlug["back-squat"]?.first?.measurements == [
            Measurement(metric: "reps", value: 5, unit: "reps"),
            Measurement(metric: "load_lb", value: 165, unit: "lb"),
            Measurement(metric: "rpe", value: 7, unit: "RPE"),
        ])
        #expect(bySlug["pull-up"]?.map { $0.measurements[0].value } == [5, 5, 5, 3])
        #expect(bySlug["pull-up"]?.first?.measurements.count == 2) // bodyweight: no load
        #expect(bySlug["dumbbell-row"]?.count == 4) // db-row alias merged
        #expect(bySlug["farmer-carry"]?.first?.measurements == [
            Measurement(metric: "distance_m", value: 30, unit: "m"),
            Measurement(metric: "load_lb_hand", value: 52.9, unit: "lb/hand"),
        ])
        #expect(bySlug["plank"]?.first?.measurements.first == Measurement(metric: "duration_s", value: 50, unit: "s"))
        #expect(bySlug["dead-bug"] == nil)
        #expect(result.skipped == ["2026-06-19.html: barbell-row has no sets/reps", "2026-06-19.html: back-squat warm-up set"])
        #expect(result.entries.allSatisfy { $0.kind == .workout && $0.note == "Session A (reconstructed from plan)" })
        #expect(calendar.dateComponents([.year, .month, .day, .hour], from: result.entries[0].timestamp)
            == DateComponents(year: 2026, month: 6, day: 19, hour: 12))
        #expect(result.entries.map(\.timestamp) == result.entries.map(\.timestamp).sorted())
        #expect(Set(result.entries.map(\.timestamp)).count == result.entries.count)
    }

    @Test(arguments: [
        ("<html>no json here</html>", "x.html: no session-data JSON"),
        (html("session-data", "{ not json"), "x.html: no session-data JSON"),
        (html("session-data", #"{ "date": "2026-05-20", "planned": true, "exercises": [] }"#), "x.html: not a completed session"),
        (html("session-data", #"{ "completed": true, "exercises": [] }"#), "x.html: missing date"),
    ])
    func badSessionFilesAreSkippedNotFatal(file: String, reason: String) {
        let result = HistoryImporter.session(html: file, fileName: "x.html", calendar: calendar)
        #expect(result.entries.isEmpty)
        #expect(result.skipped == [reason])
    }

    @Test func markdownSessionReadsTheTable() {
        let result = HistoryImporter.session(markdown: """
            ---
            date: 2026-05-12
            session_label: Session A — Full Body
            completed: true
            sets_by_pattern:
              squat: 3
            ---

            ## Actual Work

            | Exercise | Sets | Reps | Load | Notes |
            |---|---|---|---|---|
            | Goblet Squat | 3 | 8 | 60 lb | Solid depth. |
            | Dumbbell Row | 2 | 10 | 45 lb/hand | Easy. |
            | Plank | 3 | 45s | BW | Held form throughout. |
            """, fileName: "2026-05-12.md", calendar: calendar)
        #expect(result.skipped.isEmpty)
        #expect(result.entries.map(\.template) == ["goblet-squat", "goblet-squat", "goblet-squat",
                                                    "dumbbell-row", "dumbbell-row", "plank", "plank", "plank"])
        #expect(result.entries[3].measurements[1] == Measurement(metric: "load_lb_hand", value: 45, unit: "lb/hand"))
        #expect(result.entries[0].note == "Session A — Full Body — Solid depth.")
    }

    @Test(arguments: [
        ("95 lb", Measurement(metric: "load_lb", value: 95, unit: "lb")),
        ("22-24kg/hand", Measurement(metric: "load_lb_hand", value: 52.9, unit: "lb/hand")),
        ("BW", nil),
    ])
    func load(text: String, expected: AICoach.Measurement?) {
        #expect(HistoryImporter.load(text) == expected)
    }

    @Test func dailyLogMealsAndSleep() {
        let result = HistoryImporter.daily(html: html("daily-log-data", """
            { "date": "2026-05-18",
              "meals": [
                { "meal_name": "Greek yogurt protein bowl", "calories_est": 620, "protein_g": 58, "carbs_g": 72,
                  "fat_g": 8, "timestamp": "2026-05-18T07:30:00" },
                { "meal_name": "Protein shake", "calories_est": 175, "protein_g": 27 }
              ],
              "sleep": { "hours": 7, "quality": 3, "quality_max": 5, "notes": "restless" } }
            """), fileName: "2026-05-18.html", calendar: calendar)
        #expect(result.entries.map(\.kind) == [.meal, .meal, .sleep])
        #expect(result.entries[0].note == "Greek yogurt protein bowl")
        #expect(result.entries[0].measurements.map(\.metric) == ["kcal", "protein_g", "carbs_g", "fat_g"])
        #expect(calendar.component(.hour, from: result.entries[0].timestamp) == 7)
        #expect(result.entries[1].measurements.count == 2)
        #expect(result.entries[2].measurements == [
            Measurement(metric: "sleep_h", value: 7, unit: "h"), Measurement(metric: "sleep_quality", value: 3, unit: "/5"),
        ])
    }

    @Test func unloggedSleepAndBodyOnlyDaysAddNothing() {
        let result = HistoryImporter.daily(html: html("daily-log-data", """
            { "date": "2026-07-12", "type": "body-comp-baseline", "body": { "weight_lb": 201 }, "meals": [], "sleep": null }
            """), fileName: "2026-07-12.html", calendar: calendar)
        #expect(result.entries.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test func bodyMeasurementsFromProfile() {
        let result = HistoryImporter.bodyMeasurements(profileJSON: """
            { "body_measurements": [
                { "date": "2026-07-12", "weight_lb": 201, "waist_in": 38.5, "note": "baseline" },
                { "date": "2026-07-13", "weight_lb": 197, "waist_in": null }
            ] }
            """, calendar: calendar)
        #expect(result.entries.map(\.kind) == [.bodyweight, .bodyweight])
        #expect(result.entries[0].measurements.map(\.metric) == ["weight_lb", "waist_in"])
        #expect(result.entries[1].measurements == [Measurement(metric: "weight_lb", value: 197, unit: "lb")])
    }
}

struct TrainingTests {
    @Test(arguments: [
        (165.0, 5.0, 7.0 as Double?, 185.625 as Double?),
        (135, 1, nil, 135),
        (100, 11, 7, nil),  // Brzycki only holds for 1–10 reps
        (100, 5, 9, nil),   // and RPE ≤ 8
    ])
    func brzycki(load: Double, reps: Double, rpe: Double?, expected: Double?) {
        #expect(Training.estimated1RM(loadLb: load, reps: reps, rpe: rpe) == expected)
    }

    @Test func volumeCountsTheLast28CalendarDays() {
        let day = { (d: Int) in calendar.date(from: DateComponents(year: 2026, month: 7, day: d, hour: 12))! }
        let sets = [1, 14, 15, 15, 30].map { LoggedSet(date: day($0), exercise: "x", pattern: "push", measurements: []) }
            + [LoggedSet(date: day(20), exercise: "y", pattern: nil, measurements: [])]
        #expect(Training.setsByPattern(sets, endingOn: day(12 + 30), calendar: calendar) == ["push": 3])
    }
}

/// FIT-13 acceptance: regenerating from the imported history reproduces fitness-planner's profile.json
/// (generated 2026-07-12). Runs against the bundled history, which Debug builds include.
@MainActor
struct HistoryAcceptanceTests {
    @Test func regeneratedStrengthAndVolumeMatchProfile() throws {
        let patterns = Dictionary(uniqueKeysWithValues: try Seeder.decode([TemplateSeed].self, "exercises", .main)
            .map { ($0.slug, $0.values("movement_pattern").first) })
        let sets = try Seeder.decode([LogSeed].self, "history", .main)
            .filter { $0.kind == .workout }
            .map { LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: patterns[$0.template ?? ""] ?? nil,
                             measurements: $0.measurements) }
        #expect(sets.allSatisfy { $0.pattern != nil })

        // profile.json strength_levels.*.estimated_1rm_lb
        let estimates = Training.estimated1RMs(sets).mapValues { Int($0.rounded()) }
        #expect(estimates["back-squat"] == 186)
        #expect(estimates["bench-press"] == 174)
        #expect(estimates["deadlift"] == 248)

        // profile.json movement_patterns.*.recent_sets_28d
        let generatedAt = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        #expect(Training.setsByPattern(sets, endingOn: generatedAt)
            == ["squat": 18, "hinge": 18, "push": 30, "pull": 60, "carry": 18, "core": 36])
    }
}
