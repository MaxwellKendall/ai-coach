import Foundation

/// TKL-802 (the approved prototype on TKL-800, https://claude.ai/artifact/56LL6q28Kw1gdbeYr2BUpe): what the "today's
/// workout" widget knows, written by the app to the App Group whenever the plan or a log changes. It holds this week,
/// next week and every later week the plan reaches (up to 12 weeks), so the widget can roll over at midnight to the next
/// day, and to the next week's dots, without the app opening. Foundation only: the widget extension compiles this file too.
struct TodaySnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.com.maxwellkendall.aicoach"
    static let fileName = "today.json"

    /// There's a program or planned training at all; otherwise the widget asks to set up.
    var setUp: Bool
    /// The chosen plate's raw value (Plate in App/Theme.swift).
    var plate: String
    /// Consecutive days, each at the start of its day.
    var days: [Day]

    struct Lift: Codable, Equatable, Sendable {
        var name: String
        /// The word people say: "Squat" for Back Squat.
        var short: String
        var sets: Int
        /// "5", or a hold's "45s"; empty when the plan gives neither.
        var reps: String
        var load: Double?

        /// "3×5 · 225", "3×8", "3×45s".
        var dose: String {
            let count = reps.isEmpty ? "\(sets) sets" : "\(sets)×\(reps)"
            return count + (load.map { " · " + TodaySnapshot.number($0) } ?? "")
        }
    }

    struct Done: Codable, Equatable, Sendable {
        var sets: Int
        var volume: Double
        /// "Squat 225×5": the heaviest set.
        var best: String?
        var at: Date
    }

    struct Day: Codable, Equatable, Sendable {
        var date: Date
        /// The session's title; nil on a rest day.
        var title: String?
        var lifts: [Lift] = []
        var minutes: Int?
        /// The usual start, in minutes after midnight, when it's known.
        var usual: Int?
        var done: Done?

        var isWorkout: Bool { title != nil }
    }

    // MARK: How far ahead

    /// The fewest days a snapshot holds (this week and next) and the most (12 weeks, a whole block of a program).
    static let minDays = 14
    static let maxDays = 84

    /// How many days, from the week's Sunday, the snapshot holds: through the Saturday of the week of the last planned
    /// workout, so the widget keeps rolling over while the app stays closed, within `minDays...maxDays`.
    static func horizon(from sunday: Date, through lastPlanned: Date?, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: sunday)
        guard let lastPlanned,
              let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: lastPlanned)).day else { return minDays }
        let weeks = offset / 7 + 1
        return min(max(weeks * 7, minDays), maxDays)
    }

    // MARK: What the widget shows on a day

    enum State: Equatable, Sendable { case workout, rest, done, notSetUp, noData }

    struct Dot: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case done, today, rest, planned }
        var letter: String
        var kind: Kind
    }

    struct Content: Equatable, Sendable {
        var state: State
        var day: Day?
        /// The next planned session after this day, within the snapshot.
        var next: Day?
        /// This day's week, Sunday first.
        var week: [Dot] = []
        var doneThisWeek = 0
        var plannedThisWeek = 0
    }

    static func content(_ snapshot: TodaySnapshot?, on date: Date, calendar: Calendar = .current) -> Content {
        snapshot?.content(on: date, calendar: calendar) ?? Content(state: .noData)
    }

    func content(on date: Date, calendar: Calendar = .current) -> Content {
        guard setUp else { return Content(state: .notSetUp) }
        let start = calendar.startOfDay(for: date)
        guard let day = days.first(where: { calendar.isDate($0.date, inSameDayAs: start) }) else { return Content(state: .noData) }
        let state: State = day.done != nil ? .done : day.isWorkout ? .workout : .rest
        let next = days.first { $0.date > start && $0.isWorkout && $0.done == nil }
        let sunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: start), to: start)!
        let letters = calendar.veryShortWeekdaySymbols
        var week: [Dot] = []
        var done = 0, planned = 0
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: sunday)!
            let shown = days.first { calendar.isDate($0.date, inSameDayAs: date) }
            if shown?.done != nil { done += 1 }
            if shown?.isWorkout == true || shown?.done != nil { planned += 1 }
            let kind: Dot.Kind = shown?.done != nil ? .done : date == start ? .today : shown?.isWorkout == true ? .planned : .rest
            week.append(Dot(letter: letters[calendar.component(.weekday, from: date) - 1], kind: kind))
        }
        return Content(state: state, day: day, next: next, week: week, doneThisWeek: done, plannedThisWeek: planned)
    }

    /// When the widget's content changes on its own: now, then each midnight up to the day after the last one known
    /// (which shows no data until the app writes again).
    func timeline(from now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        guard let last = days.last?.date, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return dates }
        var midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        while midnight <= end {
            dates.append(midnight)
            midnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        }
        return dates
    }

    // MARK: Formatting

    /// "6 PM", "6:30 PM".
    static func clock(_ minute: Int) -> String {
        let hour = minute / 60 % 24, minutes = minute % 60
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return (minutes == 0 ? "\(twelve)" : "\(twelve):\(String(format: "%02d", minutes))") + (hour < 12 ? " AM" : " PM")
    }

    /// "225", "22.5", "9,450".
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }

    // MARK: Opening the app

    /// barbrabell://today opens Today (a tap anywhere on the widget); barbrabell://start starts today's workout (Start).
    enum Link: String, Sendable {
        case today, start
        static let scheme = "barbrabell"

        init?(_ url: URL) {
            guard url.scheme == Self.scheme, let link = Link(rawValue: url.host() ?? "") else { return nil }
            self = link
        }

        var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }
    }

    // MARK: The file

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: fileName)
    }

    static func read(from url: URL? = TodaySnapshot.url) -> TodaySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TodaySnapshot.self, from: data)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
