import Foundation

enum Daily {
    /// Sum of `metric` per calendar day, oldest first. Days where it wasn't logged are left out, not zero.
    static func totals(_ measurements: [(date: Date, measurements: [Measurement])], metric: String,
                       calendar: Calendar = .current) -> [DatedValue] {
        var byDay: [Date: Double] = [:]
        for entry in measurements {
            for measurement in entry.measurements where measurement.metric == metric {
                byDay[calendar.startOfDay(for: entry.date), default: 0] += measurement.value
            }
        }
        return byDay.keys.sorted().map { DatedValue(date: $0, value: byDay[$0]!) }
    }
}
