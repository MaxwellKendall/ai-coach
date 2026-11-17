import Foundation
import SwiftData
import Testing
@testable import AICoach

/// TKL-753: every change to a session is saved as it's made, so a session can be emptied and saved, and Undo can
/// write it back over no rows at all. The session's day, slot and plan come from an anchor kept before the change.
@MainActor
struct SessionSaveTests {
    @Test func anEmptiedSessionIsSavedAndUndoRestoresItFromItsAnchor() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat", attributes: [])
        let bench = Template(kind: .exercise, name: "Bench Press", slug: "bench-press", attributes: [])
        context.insert(squat)
        context.insert(bench)
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plan = Plan(weekContaining: day)
        context.insert(plan)
        let items = [squat, bench].enumerated().map { index, template in
            let item = PlannedActivity(kind: .workout, date: day + TimeInterval(index), slot: "Lower A", templateRef: template.id,
                                       targets: [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
                                                 Measurement(metric: "load_lb", value: 135, unit: "lb")])
            item.plan = plan
            context.insert(item)
            return item
        }
        try context.save()
        let templates = [squat, bench]
        let before = Planner.session(items, templates: templates)
        let anchor = Planner.Anchor(items)
        #expect(anchor != nil)

        // Every lift removed: the rows go.
        var empty = before
        while !empty.blocks.isEmpty { empty.remove(block: 0, movement: 0) }
        let written = Planner.save(empty, over: items, templates: templates, in: context, anchor: anchor)
        try context.save()
        #expect(written.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlannedActivity>()).isEmpty)

        // Undo: written back over no rows, on the same day, slot and plan.
        let restored = Planner.save(before, over: written, templates: templates, in: context, anchor: anchor)
        try context.save()
        #expect(restored.count == 2)
        #expect(Planner.session(restored, templates: templates).items.map(\.exercise) == ["back-squat", "bench-press"])
        #expect(restored.allSatisfy { $0.slot == "Lower A" && $0.plan === plan && Calendar.current.isDate($0.date, inSameDayAs: day) })

        // Without an anchor there is nothing to say where an empty session's rows go: nothing is written.
        #expect(Planner.save(before, over: [], templates: templates, in: context).isEmpty)
    }
}
