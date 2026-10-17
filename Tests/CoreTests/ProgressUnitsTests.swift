import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-167: an account's synced units, and what the server's progress (infra/lambda/progress.ts) derives from them.
/// Applied here as a phone signing in would, the app's WeekReport, Wins and Streak must give the same answers, so an
/// agent's get_progress and get_week_review say what the phone shows. infra/test/progressParity.test.ts writes the
/// fixture.
@MainActor
struct ProgressUnitsTests {
    struct Fixture: Decodable {
        struct Expected: Decodable {
            struct Review: Decodable {
                struct Numbers: Decodable {
                    var workoutsDone: Int, workoutsPlanned: Int, sets: Int, push: Int, pull: Int
                    var protein: Double?, kcal: Double?, sleep: Double?, weight: Double?, weightChange: Double?
                }
                struct GoalRow: Decodable {
                    struct CheckIn: Decodable { var proposed: Double, ahead: Bool, weeksLeft: Int }
                    var metric: String, from: Double, to: Double, pace: String, forecast: Double?, perWeek: Double, checkIn: CheckIn?
                }
                struct Alert: Decodable { var title: String, detail: String, area: String? }
                var programWeek: Int, programWeeks: Int, numbers: Numbers, goals: [GoalRow], alerts: [Alert], headline: String, subline: String
            }
            struct Win: Decodable { var key: String, day: String, value: Double, previous: Double? }
            struct Streak: Decodable { var weeks: Int, thisWeek: String, line: String? }
            var review: Review, wins: [Win], streak: Streak
        }
        var expected: Expected
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func at(_ day: String, hour: Int = 12) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
    }

    func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    @Test func theAppDerivesWhatTheServerSays() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/progress-units.json")
        let data = try Data(contentsOf: url)
        let expected = try JSONDecoder().decode(Fixture.self, from: data).expected
        let units = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["units"] as? [String: Any])

        let context = ModelContext(try AppSchema.container(inMemory: true))
        // The catalog's movement patterns for the exercises the units use.
        let patterns = ["back-squat": "squat", "bench-press": "push", "bent-over-barbell-row": "pull", "deadlift": "hinge", "pull-up": "pull",
                        "romanian-deadlift": "hinge"]
        for (slug, pattern) in patterns {
            context.insert(Template(kind: .exercise, name: slug, slug: slug, attributes: [TemplateAttribute(key: "movement_pattern", values: [pattern])]))
        }
        for (key, value) in units {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            try SyncUnits.apply(key, body: body, in: context)
        }
        try context.save()
        let profile = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        let goals = try context.fetch(FetchDescriptor<Goal>())
        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let planned = try context.fetch(FetchDescriptor<PlannedActivity>())
        let templates = try context.fetch(FetchDescriptor<Template>())

        // The weekly review of Sunday Oct 4 to Saturday Oct 10, at noon on the Saturday.
        let report = WeekReport.make(for: at("2026-10-10"), profile: profile, goals: goals, entries: entries, planned: planned, templates: templates)
        let review = expected.review
        #expect(report.programWeek == review.programWeek && report.programWeeks == review.programWeeks)
        let n = report.numbers, e = review.numbers
        let counts: [Int] = [n.workoutsDone, n.workoutsPlanned, n.sets, n.push, n.pull]
        #expect(counts == [e.workoutsDone, e.workoutsPlanned, e.sets, e.push, e.pull])
        func close(_ a: Double?, _ b: Double?) -> Bool { a == nil ? b == nil : b != nil && abs(a! - b!) < 0.01 }
        #expect(close(n.protein, e.protein) && close(n.kcal, e.kcal) && close(n.sleep, e.sleep), "\(n)")
        #expect(close(n.weight, e.weight) && close(n.weightChange, e.weightChange), "\(n)")
        // The store keeps goals in no set order.
        #expect(Set(report.goals.map(\.goal.metric)) == Set(review.goals.map(\.metric)))
        for want in review.goals {
            let row = try #require(report.goals.first { $0.goal.metric == want.metric })
            let pace: String = switch row.week.pace { case .starting: "starting"; case .behind: "behind"; case .onPace: "onPace"; case .ahead: "ahead" }
            #expect(row.week.from == want.from && row.week.to == want.to && pace == want.pace, "\(want.metric)")
            #expect(close(row.forecast, want.forecast) && close(row.perWeek, want.perWeek), "\(want.metric)")
            let got: Double? = row.checkIn?.proposed, wanted: Double? = want.checkIn?.proposed
            #expect(got == wanted, "\(want.metric)")
            #expect(row.checkIn?.ahead == want.checkIn?.ahead, "\(want.metric)")
            #expect(row.checkIn?.weeksLeft == want.checkIn?.weeksLeft, "\(want.metric)")
        }
        #expect(report.alerts.map(\.title) == review.alerts.map(\.title))
        #expect(report.alerts.map(\.detail) == review.alerts.map(\.detail))
        #expect(report.alerts.map(\.area) == review.alerts.map(\.area))
        #expect(report.headline == review.headline)
        #expect(report.subline == review.subline)

        // Wins and the streak on Saturday Oct 17, as WinFeed and Today gather them.
        let today = at("2026-10-17")
        let start = try #require(profile.programStart), end = try #require(profile.targetDate)
        let sets = Planner.loggedSets(entries, templates: templates)
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        let tracked = goals.filter { $0.status == .active }.compactMap { goal in
            GoalOption.all.contains { $0.metric == goal.metric } ? goal.baseline.map {
                Wins.Goal(metric: goal.metric, unit: goal.unit, baseline: $0, target: goal.target)
            } : nil
        }
        let plannedDays = planned.filter { $0.kind == .workout }.map(\.date)
        let workoutDays = entries.filter { $0.kind == .workout }.map(\.timestamp)
        let wins = Wins.detect(goals: tracked, sets: sets, weighIns: weighIns, since: start, end: end, plannedDays: plannedDays,
                               workoutDays: workoutDays, today: today, calendar: calendar)
        #expect(wins.map(\.key) == expected.wins.map(\.key))
        #expect(wins.map { dayString($0.date) } == expected.wins.map(\.day))
        #expect(wins.map(\.value) == expected.wins.map(\.value))
        #expect(wins.map(\.previous) == expected.wins.map(\.previous))

        let status = Streak.status(since: start, plannedDays: plannedDays, workoutDays: workoutDays, today: today, calendar: calendar)
        let kind: String = switch status.thisWeek { case .onTrack: "onTrack"; case .full: "full"; case .atRisk: "atRisk"; case .broken: "broken" }
        #expect(status.weeks == expected.streak.weeks && kind == expected.streak.thisWeek)
        #expect(Streak.line(status, today: today, calendar: calendar) == expected.streak.line)
    }
}
