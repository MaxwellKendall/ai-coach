import Foundation

/// Bundled history format: one entry per logged set, meal, night of sleep or weigh-in.
struct LogSeed: Codable, Hashable, Sendable {
    var kind: ActivityKind
    var timestamp: Date
    /// Exercise slug, resolved to a Template when seeded.
    var template: String?
    var measurements: [Measurement]
    var note: String
}

/// Converts fitness-planner history (session-logs, daily-logs, profile.json body measurements) into log seeds.
/// A bad file or row is skipped and reported, never fatal (CLAUDE.md §6).
enum HistoryImporter {
    struct Result {
        var entries: [LogSeed] = []
        var skipped: [String] = []

        /// Logs only have a date, so sets are a second apart to keep the order they were done in.
        func inSessionOrder() -> Result {
            var copy = self
            for index in copy.entries.indices { copy.entries[index].timestamp += TimeInterval(index) }
            return copy
        }
    }

    /// Older logs used short slugs.
    static let aliases = ["db-row": "dumbbell-row"]

    /// Exercises the history uses that have no exercise-library card.
    static let extraExercises = [
        TemplateSeed(kind: .exercise, name: "Dead Bug", slug: "dead-bug",
                     attributes: [TemplateAttribute(key: "movement_pattern", values: ["core"])]),
    ]

    // MARK: Session logs

    static func session(html: String, fileName: String, calendar: Calendar = .current) -> Result {
        guard let data = jsonBlock(html, id: "session-data") else {
            return Result(skipped: ["\(fileName): no session-data JSON"])
        }
        guard data["completed"] as? Bool == true else {
            return Result(skipped: ["\(fileName): not a completed session"])
        }
        guard let day = (data["date"] as? String).flatMap({ date($0, calendar: calendar) }) else {
            return Result(skipped: ["\(fileName): missing date"])
        }
        var note = data["session_label"] as? String ?? ""
        if data["reconstructed"] as? Bool == true { note += " (reconstructed from plan)" }

        var result = Result()
        for exercise in data["exercises"] as? [[String: Any]] ?? [] {
            let slug = exercise["slug"] as? String ?? "?"
            if exercise["skipped"] as? Bool == true { continue }
            if exercise["note"] as? String == "warm-up" {
                result.skipped.append("\(fileName): \(slug) warm-up set")
                continue
            }
            var load: Measurement?
            if let lb = exercise["load_lb"] as? Double {
                load = Measurement(metric: "load_lb", value: lb, unit: "lb")
            } else if let lb = exercise["load_lb_hand"] as? Double {
                load = Measurement(metric: "load_lb_hand", value: lb, unit: "lb/hand")
            } else if let text = exercise["load"] as? String {
                load = self.load(text)
            }
            let sets = self.sets(slug: slug, count: exercise["sets"] as? Int, reps: exercise["reps"],
                                 load: load, rpe: exercise["rpe"] as? Double, timestamp: day, note: note)
            if sets.isEmpty { result.skipped.append("\(fileName): \(slug) has no sets/reps") }
            result.entries += sets
        }
        return result.inSessionOrder()
    }

    /// The one pre-JSON log (2026-05-12.md): front matter plus an `| Exercise | Sets | Reps | Load | Notes |` table.
    static func session(markdown: String, fileName: String, calendar: Calendar = .current) -> Result {
        guard let card = MarkdownCard(markdown),
              let day = card.field("date").first.flatMap({ date($0, calendar: calendar) }) else {
            return Result(skipped: ["\(fileName): no front matter date"])
        }
        let label = card.field("session_label").first ?? ""
        let rows = markdown.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("|") }
            .map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !($0.first ?? "").hasPrefix("---") }
        guard let header = rows.first?.map({ $0.lowercased() }),
              let name = header.firstIndex(of: "exercise"), let sets = header.firstIndex(of: "sets"),
              let reps = header.firstIndex(of: "reps"), let load = header.firstIndex(of: "load") else {
            return Result(skipped: ["\(fileName): no exercise table"])
        }
        let notes = header.firstIndex(of: "notes")

        var result = Result()
        for row in rows.dropFirst() where row.count == header.count {
            let slug = Slug.make(row[name])
            let note = [label, notes.map { row[$0] } ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
            let entries = self.sets(slug: slug, count: Int(row[sets]), reps: row[reps], load: self.load(row[load]),
                                    rpe: nil, timestamp: day, note: note)
            if entries.isEmpty { result.skipped.append("\(fileName): \(row[name]) has no sets/reps") }
            result.entries += entries
        }
        return result.inSessionOrder()
    }

    /// One entry per set. `reps` may be a number, per-set reps ("5,5,5,3"), a duration ("50s"),
    /// a distance ("30m") or per side ("8/side").
    static func sets(slug: String, count: Int?, reps: Any?, load: Measurement?, rpe: Double?,
                     timestamp: Date, note: String) -> [LogSeed] {
        var perSet: [Measurement] = []
        if let number = reps as? Double {
            perSet = Array(repeating: Measurement(metric: "reps", value: number, unit: "reps"), count: count ?? 0)
        } else if let text = reps as? String {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = parts.compactMap(work)
            guard parsed.count == parts.count else { return [] }
            perSet = parsed.count > 1 ? parsed : Array(repeating: parsed[0], count: count ?? 0)
        }
        let slug = aliases[slug] ?? slug
        return perSet.map { work in
            var measurements = [work]
            if let load { measurements.append(load) }
            if let rpe { measurements.append(Measurement(metric: "rpe", value: rpe, unit: "RPE")) }
            return LogSeed(kind: .workout, timestamp: timestamp, template: slug, measurements: measurements, note: note)
        }
    }

    private static func work(_ text: String) -> Measurement? {
        guard let match = text.lowercased().wholeMatch(of: /(\d+(?:\.\d+)?)\s*(s|m|\/side)?/),
              let value = Double(match.1) else { return nil }
        switch match.2 {
        case "s": return Measurement(metric: "duration_s", value: value, unit: "s")
        case "m": return Measurement(metric: "distance_m", value: value, unit: "m")
        default: return Measurement(metric: "reps", value: value, unit: "reps")
        }
    }

    /// "95 lb", "24 kg/hand", "22-24kg/hand", "BW". Ranges take the top number; bodyweight has no load.
    static func load(_ text: String) -> Measurement? {
        let lower = text.lowercased()
        guard let value = lower.matches(of: /\d+(?:\.\d+)?/).compactMap({ Double($0.0) }).last else { return nil }
        let lb = lower.contains("kg") ? (value * 2.20462 * 10).rounded() / 10 : value
        return lower.contains("/hand")
            ? Measurement(metric: "load_lb_hand", value: lb, unit: "lb/hand")
            : Measurement(metric: "load_lb", value: lb, unit: "lb")
    }

    // MARK: Daily logs

    /// Meals and sleep. Body measurements come from profile.json, which also has the ones logged elsewhere.
    static func daily(html: String, fileName: String, calendar: Calendar = .current) -> Result {
        guard let data = jsonBlock(html, id: "daily-log-data") else {
            return Result(skipped: ["\(fileName): no daily-log-data JSON"])
        }
        guard let dateText = data["date"] as? String, let day = date(dateText, calendar: calendar) else {
            return Result(skipped: ["\(fileName): missing date"])
        }
        var result = Result()
        for meal in data["meals"] as? [[String: Any]] ?? [] {
            let measurements = [("calories_est", "kcal", "kcal"), ("protein_g", "protein_g", "g"),
                                ("carbs_g", "carbs_g", "g"), ("fat_g", "fat_g", "g")].compactMap { key, metric, unit in
                (meal[key] as? Double).map { Measurement(metric: metric, value: $0, unit: unit) }
            }
            let time = (meal["timestamp"] as? String).flatMap { date($0, calendar: calendar) } ?? day
            result.entries.append(LogSeed(kind: .meal, timestamp: time, measurements: measurements,
                                          note: meal["meal_name"] as? String ?? ""))
        }
        if let sleep = data["sleep"] as? [String: Any], let hours = sleep["hours"] as? Double {
            var measurements = [Measurement(metric: "sleep_h", value: hours, unit: "h")]
            if let quality = sleep["quality"] as? Double {
                measurements.append(Measurement(metric: "sleep_quality", value: quality,
                                                unit: "/\((sleep["quality_max"] as? Int) ?? 5)"))
            }
            let time = (sleep["logged_at"] as? String).flatMap { date($0, calendar: calendar) } ?? day
            result.entries.append(LogSeed(kind: .sleep, timestamp: time, measurements: measurements,
                                          note: sleep["notes"] as? String ?? ""))
        }
        return result
    }

    static func bodyMeasurements(profileJSON: String, calendar: Calendar = .current) -> Result {
        guard let profile = try? JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any] else {
            return Result(skipped: ["profile.json: not JSON"])
        }
        var result = Result()
        for row in profile["body_measurements"] as? [[String: Any]] ?? [] {
            guard let day = (row["date"] as? String).flatMap({ date($0, calendar: calendar) }) else { continue }
            let measurements = [("weight_lb", "lb"), ("waist_in", "in")].compactMap { metric, unit in
                (row[metric] as? Double).map { Measurement(metric: metric, value: $0, unit: unit) }
            }
            if measurements.isEmpty { continue }
            result.entries.append(LogSeed(kind: .bodyweight, timestamp: day, measurements: measurements,
                                          note: row["note"] as? String ?? ""))
        }
        return result
    }

    // MARK: Helpers

    static func jsonBlock(_ html: String, id: String) -> [String: Any]? {
        guard let start = html.range(of: "<script type=\"application/json\" id=\"\(id)\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { return nil }
        let json = Data(html[start.upperBound..<end.lowerBound].utf8)
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    /// "2026-05-18" (noon, so it never shifts a day) or "2026-05-18T07:30:00", in the calendar's time zone.
    static func date(_ text: String, calendar: Calendar) -> Date? {
        guard let match = text.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/) else { return nil }
        return calendar.date(from: DateComponents(
            year: Int(match.1), month: Int(match.2), day: Int(match.3),
            hour: match.4.flatMap { Int($0) } ?? 12, minute: match.5.flatMap { Int($0) } ?? 0))
    }
}
