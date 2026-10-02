import Foundation

/// A cook window or grocery run placed on a day of the week. Recipes and the list come from FIT-11.
struct KitchenBlock: Equatable, Sendable {
    var kind: ActivityKind
    var date: Date
    var label: String
    var hours: Double
}

enum KitchenSchedule {
    /// plan.md step 9: grocery run in the morning (9:00); a cook on the same day follows it (13:00),
    /// other cooks are evenings (18:00).
    static func week(startingOn monday: Date, cookWindows: [CookWindow], groceryDay: Int?,
                     calendar: Calendar = .current) -> [KitchenBlock] {
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: day, to: monday)!)!
        }
        var blocks = cookWindows.map {
            KitchenBlock(kind: .cook, date: at($0.day, $0.day == groceryDay ? 13 : 18), label: $0.label, hours: $0.hours)
        }
        if let groceryDay { blocks.append(KitchenBlock(kind: .grocery, date: at(groceryDay, 9), label: "Grocery run", hours: 1)) }
        return blocks.sorted { $0.date < $1.date }
    }
}
