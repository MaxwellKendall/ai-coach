import Foundation

/// FIT-179: race-time goals ("10K in 55:00"), metric `run_<meters>m.time_s` in seconds, lower being better. A run is a
/// workout entry on one of the catalog's runs with `distance_m` and `duration_s`; its predicted race time is Riegel's,
/// T2 = T1 × (D2 / D1)^1.06. The server's infra/lambda/running.ts is the same, held to it by ProgressUnitsTests.
enum Running {
    /// The catalog's runs: outdoors first, the one a run is logged on by default.
    static let runs: Set<String> = ["trail-running-walking", "running-treadmill", "jogging-treadmill"]
    static let outdoor = "trail-running-walking"

    static func metric(meters: Double) -> String { "run_\(Int(meters.rounded()))m.time_s" }

    /// A race-time metric's distance in meters.
    static func meters(_ metric: String) -> Double? {
        guard metric.hasPrefix("run_"), metric.hasSuffix("m.time_s") else { return nil }
        return Double(metric.dropFirst(4).dropLast(8))
    }

    /// A run's time carried to another distance; only runs a quarter of it or longer, and 1.6 km or longer, count.
    static func riegel(seconds: Double, from: Double, to: Double) -> Double? {
        from >= max(1600, to / 4) ? seconds * pow(to / from, 1.06) : nil
    }

    /// The fastest time the runs predict for `meters` since `start`, whole seconds, with the run behind it.
    static func best(_ meters: Double, sets: [LoggedSet], since start: Date) -> (time: Double, run: LoggedSet)? {
        var top: (time: Double, run: LoggedSet)?
        for set in sets where runs.contains(set.exercise) && set.date >= start {
            guard let distance = set.value("distance_m"), let seconds = set.value("duration_s"),
                  let time = riegel(seconds: seconds, from: distance, to: meters) else { continue }
            if top.map({ time.rounded() < $0.time }) ?? true { top = (time.rounded(), set) }
        }
        return top
    }

    /// A time as typed: "48:30", "1:02:10", or a number of minutes.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map { Double(String($0)) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 }
        let total = values.count == 1 ? values[0] * 60 : values.count == 2 ? values[0] * 60 + values[1] : values[0] * 3600 + values[1] * 60 + values[2]
        return total > 0 ? total.rounded() : nil
    }

    /// "54:30", "1:45:30".
    static func clock(_ total: Double) -> String {
        let t = Int(total.rounded()), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "5:30/km".
    static func pace(seconds: Double, meters: Double) -> String { "\(clock(seconds / (meters / 1000)))/km" }

    /// "8 km", "5.2 km".
    static func km(_ meters: Double) -> String { "\(Coach.number((meters / 100).rounded() / 10)) km" }
}
