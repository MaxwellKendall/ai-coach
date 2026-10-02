import Foundation
import SwiftData
import Testing
@testable import AICoach

@MainActor
struct ModelTests {
    @Test func persistsAcrossContainers() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).store")
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        do {
            let context = ModelContext(try AppSchema.container(url: url))
            let goal = Goal(kind: .training, metric: "bench_1rm", target: 225, unit: "lb")
            let plan = Plan(weekContaining: start)
            let bench = PlannedActivity(kind: .workout, date: start,
                                        targets: [Measurement(metric: "load_lb", value: 185, unit: "lb")])
            plan.items.append(bench)
            let log = LogEntry(kind: .workout, plannedRef: bench.id,
                               measurements: [Measurement(metric: "reps", value: 5, unit: "reps"),
                                              Measurement(metric: "load_lb", value: 185, unit: "lb")])
            context.insert(goal)
            context.insert(plan)
            context.insert(log)
            context.insert(Template(kind: .exercise, name: "Bench Press", slug: "bench-press",
                                    attributes: ["pattern": "push"]))
            context.insert(Win(kind: .pr, goalRef: goal.id, logRef: log.id, date: start))
            try context.save()
        }

        let context = ModelContext(try AppSchema.container(url: url))
        let plan = try #require(try context.fetch(FetchDescriptor<Plan>()).first)
        #expect(plan.items.first?.targets == [Measurement(metric: "load_lb", value: 185, unit: "lb")])
        let log = try #require(try context.fetch(FetchDescriptor<LogEntry>()).first)
        #expect(log.plannedRef == plan.items.first?.id)
        #expect(log.measurements.count == 2)
        #expect(try context.fetch(FetchDescriptor<Goal>()).first?.target == 225)
        #expect(try context.fetch(FetchDescriptor<Template>()).first?.attributes["pattern"] == "push")
        #expect(try context.fetch(FetchDescriptor<Win>()).first?.kind == .pr)
    }

    @Test func deletingPlanCascadesToItems() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let plan = Plan(weekContaining: .now)
        plan.items.append(PlannedActivity(kind: .meal, date: .now))
        context.insert(plan)
        try context.save()
        context.delete(plan)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == 0)
    }
}

struct WeekTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1 // Sunday-first locale must still key weeks by Monday
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    @Test(arguments: [
        (2026, 10, 2),  // Friday
        (2026, 9, 28),  // Monday itself
        (2026, 10, 4),  // Sunday belongs to the week that started the Monday before
    ])
    func mondayOfWeek(y: Int, m: Int, d: Int) {
        #expect(Week.monday(of: date(y, m, d), calendar: calendar) == date(2026, 9, 28, hour: 0))
    }
}
