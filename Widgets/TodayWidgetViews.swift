import SwiftUI
import WidgetKit

/// TKL-802 (the approved prototype on TKL-800, https://claude.ai/artifact/56LL6q28Kw1gdbeYr2BUpe): the "today's
/// workout" widget. Small: the day and how long. Medium: the first three lifts and Start. Large: the whole session,
/// this week's days and Start. On the Lock Screen a rectangular one (day, lifts, time) and an inline one. It shows the
/// usual time when it's known, follows light and dark and the chosen plate; a tap opens Today and Start the live
/// workout. Compiled into the app too, for the Debug widget gallery (`-widgets`).
struct TodayWidgetView: View {
    let content: TodaySnapshot.Content
    let plate: String
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            case .systemLarge, .systemExtraLarge: large
            default: small
            }
        }
        .monospacedDigit()
    }

    private var tone: TodayTone { TodayTone(plate: plate) }
    private var day: TodaySnapshot.Day? { content.day }
    private var next: TodaySnapshot.Day? { content.next }

    // MARK: Home screen

    @ViewBuilder private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch content.state {
            case .workout:
                eyebrow("Today")
                title(day?.title ?? "Workout", lines: 3)
                sub(howLong)
                Spacer(minLength: 0)
                if let usual { foot(usual) }
            case .rest:
                eyebrow("Today")
                title("Rest day")
                if let next { sub("Next: \(nextShort(next))", lines: 2) }
                Spacer(minLength: 0)
            case .done:
                check
                title("Done").padding(.top, 6)
                sub(day?.title ?? "", lines: 2)
                Spacer(minLength: 0)
                if let done = day?.done { foot("\(TodaySnapshot.number(done.volume)) lb") }
            case .notSetUp, .noData:
                title("barbrabell")
                sub(content.state == .notSetUp ? "Your workouts will show here." : "Open the app to see today's workout.", lines: 3)
                Spacer(minLength: 0)
                Text(content.state == .notSetUp ? "Set up" : "Open").font(.caption.weight(.semibold)).foregroundStyle(tone.mark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Two columns, 1 : 1.3 as in the prototype.
    private var medium: some View {
        GeometryReader { proxy in
            let left = (proxy.size.width - 12) / 2.3
            HStack(alignment: .top, spacing: 12) {
                mediumLeft.frame(width: left)
                mediumRight.frame(maxWidth: .infinity)
            }
        }
    }

    private var mediumLeft: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch content.state {
            case .workout:
                eyebrow("Today")
                title(day?.title ?? "Workout", lines: 2)
                sub(usual ?? howLong)
                Spacer(minLength: 0)
                start("Start", .start)
            case .rest:
                eyebrow("Today")
                title("Rest day")
                sub(weekDone)
                Spacer(minLength: 0)
            case .done:
                check
                title(day?.title ?? "Done", lines: 2).padding(.top, 6)
                if let done = day?.done { sub("Done at \(done.at.formatted(date: .omitted, time: .shortened))") }
                Spacer(minLength: 0)
            case .notSetUp, .noData:
                title("barbrabell")
                sub(content.state == .notSetUp ? "No plan yet" : "Nothing to show yet")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mediumRight: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch content.state {
            case .workout:
                lifts(day?.lifts ?? [], count: 3, short: true)
                if let more = day.map({ $0.lifts.count - 3 }), more > 0 { Text("+ \(more) more").font(.caption).foregroundStyle(tone.inkMuted).padding(.top, 2) }
            case .rest:
                if let next {
                    sub("Next")
                    Text("\(next.title ?? "Workout") · \(weekday(next.date, .abbreviated))")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(tone.ink).lineLimit(2).minimumScaleFactor(0.8)
                    lifts(next.lifts, count: 2, short: false)
                }
            case .done:
                if let done = day?.done { stats(done) }
            case .notSetUp, .noData:
                sub(content.state == .notSetUp ? "Open the app to plan your week, or wait for your coach's program."
                    : "Open barbrabell to see today's workout.", lines: 3)
                Spacer(minLength: 0)
                start("Open", .today)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var large: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch content.state {
            case .workout:
                eyebrow("Today" + (usual.map { " · \($0.lowercased())" } ?? ""))
                title(day?.title ?? "Workout", lines: 2)
                lifts(day?.lifts ?? [], count: 5, short: false).padding(.top, 8)
                if let more = day.map({ $0.lifts.count - 5 }), more > 0 { Text("+ \(more) more").font(.caption).foregroundStyle(tone.inkMuted).padding(.top, 4) }
                weekRow.padding(.top, 10)
                Spacer(minLength: 0)
                HStack {
                    Text(howLong)
                    Spacer()
                    start("Start", .start)
                }
                .font(.caption).foregroundStyle(tone.inkMuted)
            case .rest:
                eyebrow("Today")
                title("Rest day")
                if let next { sub("Next: \(next.title ?? "Workout") on \(weekday(next.date, .wide))" + (next.usual.map { ", usually \(TodaySnapshot.clock($0))" } ?? ""), lines: 2) }
                weekRow.padding(.top, 10)
                Spacer(minLength: 0)
                foot("\(content.doneThisWeek) of \(content.plannedThisWeek) sessions done this week")
            case .done:
                eyebrow("Today")
                title("\(day?.title ?? "Workout") · done", lines: 2)
                if let done = day?.done { stats(done).padding(.top, 8) }
                weekRow.padding(.top, 10)
                Spacer(minLength: 0)
                if let next { foot("Next: \(nextShort(next))") }
            case .notSetUp, .noData:
                title("barbrabell")
                sub(content.state == .notSetUp ? "Today's workout, this week and your usual time will show here once you have a plan."
                    : "Open barbrabell to see today's workout and this week.", lines: 3)
                Spacer(minLength: 0)
                HStack { Spacer(); start("Open", .today) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock Screen

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content.state {
            case .workout:
                Text(day?.title ?? "Workout").font(.headline).lineLimit(1)
                Text(lockLine).lineLimit(1)
            case .rest:
                Text("Rest day").font(.headline)
                if let next { Text("Next: \(nextShort(next))").lineLimit(2) }
            case .done:
                Text("✓ \(day?.title ?? "Done")").font(.headline).lineLimit(1)
                if let done = day?.done { Text("\(done.sets) sets · \(TodaySnapshot.number(done.volume)) lb").lineLimit(1) }
            case .notSetUp, .noData:
                Text("barbrabell").font(.headline)
                Text(content.state == .notSetUp ? "No plan yet" : "Open to update").lineLimit(1)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        let text: String = switch content.state {
        case .workout: (day?.title ?? "Workout") + (day?.usual.map { " · " + TodaySnapshot.clock($0) } ?? "")
        case .rest: "Rest day" + (next.map { " · \($0.title ?? "Workout") \(weekday($0.date, .abbreviated))" } ?? "")
        case .done: "✓ \(day?.title ?? "Done")"
        case .notSetUp, .noData: "barbrabell"
        }
        return Label(text, systemImage: "dumbbell.fill")
    }

    // MARK: Pieces

    private var usual: String? { day?.usual.map { "Usually \(TodaySnapshot.clock($0))" } }

    /// "4 lifts · ~55 min".
    private var howLong: String {
        var parts: [String] = []
        let count = day?.lifts.count ?? 0
        if count > 0 { parts.append(count == 1 ? "1 lift" : "\(count) lifts") }
        if let minutes = day?.minutes { parts.append("~\(minutes) min") }
        return parts.joined(separator: " · ")
    }

    /// "5 lifts · 6 PM", or how long when the usual time isn't known.
    private var lockLine: String {
        let count = day?.lifts.count ?? 0
        let when = day?.usual.map(TodaySnapshot.clock) ?? day?.minutes.map { "~\($0) min" }
        return ([count > 0 ? "\(count) lifts" : nil, when] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    private var weekDone: String { "\(content.doneThisWeek) of \(content.plannedThisWeek) done this week" }

    /// "Upper B, Thu".
    private func nextShort(_ next: TodaySnapshot.Day) -> String { "\(next.title ?? "Workout"), \(weekday(next.date, .abbreviated))" }

    private func weekday(_ date: Date, _ width: Date.FormatStyle.Symbol.Weekday) -> String { date.formatted(.dateTime.weekday(width)) }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.55).foregroundStyle(tone.mark).lineLimit(1)
    }

    private func title(_ text: String, lines: Int = 1) -> some View {
        Text(text).font(.system(size: 19, weight: .bold)).foregroundStyle(tone.ink).lineLimit(lines).minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
    }

    private func sub(_ text: String, lines: Int = 1) -> some View {
        Text(text).font(.caption).foregroundStyle(tone.inkMuted).lineLimit(lines).padding(.top, 2)
    }

    private func foot(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(tone.inkMuted).lineLimit(1)
    }

    private var check: some View {
        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(tone.good, in: .circle)
    }

    private func start(_ text: String, _ link: TodaySnapshot.Link) -> some View {
        Link(destination: link.url) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone.onAccent)
                .padding(.vertical, 6).padding(.horizontal, 14).background(tone.accent, in: .capsule)
        }
    }

    private func lifts(_ lifts: [TodaySnapshot.Lift], count: Int, short: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lifts.prefix(count).enumerated()), id: \.offset) { _, lift in
                row(short ? lift.short : lift.name, lift.dose)
            }
        }
        .padding(.top, short ? 0 : 4)
    }

    private func stats(_ done: TodaySnapshot.Done) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Sets", "\(done.sets)")
            row("Moved", "\(TodaySnapshot.number(done.volume)) lb")
            if let best = done.best { row("Best", best) }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(tone.ink).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(tone.inkMuted).lineLimit(1).layoutPriority(1)
        }
        .font(.system(size: 13))
    }

    private var weekRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(content.week.enumerated()), id: \.offset) { index, dot in
                VStack(spacing: 4) {
                    ZStack {
                        switch dot.kind {
                        case .done:
                            Circle().fill(tone.accent)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tone.onAccent)
                        case .today: Circle().strokeBorder(tone.mark, lineWidth: 2)
                        case .rest: Circle().strokeBorder(tone.fillStrong, style: StrokeStyle(lineWidth: 2, dash: [3, 2.5]))
                        case .planned: Circle().strokeBorder(tone.fillStrong, lineWidth: 2)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(dot.letter).font(.system(size: 11)).foregroundStyle(tone.inkMuted)
                }
                if index < content.week.count - 1 { Spacer(minLength: 0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(content.doneThisWeek) of \(content.plannedThisWeek) done")
    }
}

/// The design system's tokens (App/Theme.swift) and the plate's colours, each light and dark, for the widget, which
/// doesn't compile Theme.
struct TodayTone {
    var plate: String

    var surface: Color { Self.color(0xffffff, 0x16181b) }
    var ink: Color { Self.color(0x0e1013, 0xf1f2f4) }
    var inkMuted: Color { Self.color(0x575c64, 0xa2a7af) }
    var fillStrong: Color { Self.color(0xe1e4e8, 0x2a2d32) }
    var good: Color { Self.color(0x0f7d43, 0x4fd68a) }

    /// Plate.accent: the Start button and done days.
    var accent: Color {
        switch plate {
        case "red": Self.color(0xd21f2f, 0xff5a62)
        case "yellow": Self.color(0xf2c200, 0xffd21f)
        case "green": Self.color(0x0f7d43, 0x2fc774)
        default: Self.color(0x1747d6, 0x5f86ff)
        }
    }

    /// Plate.mark: the plate as text or a line.
    var mark: Color { plate == "yellow" ? Self.color(0x7a5f00, 0xffd21f) : accent }

    /// Plate.onAccent.
    var onAccent: Color { plate == "yellow" ? Self.color(0x0e1013, 0x0e1013) : Self.color(0xffffff, 0x0f1012) }

    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// The prototype's sample day in each state: the widget's placeholder and the Debug gallery.
enum TodayWidgetSample {
    static func content(_ state: TodaySnapshot.State, on today: Date = .now, calendar: Calendar = .current) -> TodaySnapshot.Content {
        snapshot(state, on: today, calendar: calendar)?.content(on: today, calendar: calendar) ?? TodaySnapshot.Content(state: .noData)
    }

    static func snapshot(_ state: TodaySnapshot.State, on today: Date = .now, calendar: Calendar = .current) -> TodaySnapshot? {
        switch state {
        case .noData: return nil
        case .notSetUp: return TodaySnapshot(setUp: false, plate: "blue", days: [])
        default: break
        }
        let lifts = [
            TodaySnapshot.Lift(name: "Back Squat", short: "Squat", sets: 3, reps: "5", load: 225),
            TodaySnapshot.Lift(name: "Bench Press", short: "Bench", sets: 3, reps: "8", load: 135),
            TodaySnapshot.Lift(name: "Romanian Deadlift", short: "RDL", sets: 3, reps: "10", load: 155),
            TodaySnapshot.Lift(name: "Pull-up", short: "Pull-up", sets: 3, reps: "8", load: nil),
            TodaySnapshot.Lift(name: "Plank", short: "Plank", sets: 3, reps: "45s", load: nil),
        ]
        let start = calendar.startOfDay(for: today)
        let sunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: start), to: start)!
        let todayOffset = calendar.dateComponents([.day], from: sunday, to: start).day ?? 0
        let days = (0..<14).map { offset -> TodaySnapshot.Day in
            let date = calendar.date(byAdding: .day, value: offset, to: sunday)!
            var day = TodaySnapshot.Day(date: date)
            // Every other day, today too unless it's the rest day's sample.
            let lifting = offset == todayOffset ? state != .rest : abs(offset - todayOffset) % 2 == (state == .rest ? 1 : 0)
            guard lifting else { return day }
            day.title = offset == todayOffset ? "Full body A" : "Upper B"
            day.lifts = offset == todayOffset ? lifts : Array(lifts.reversed())
            day.minutes = 55
            day.usual = 18 * 60
            if offset < todayOffset || (offset == todayOffset && state == .done) {
                day.done = TodaySnapshot.Done(sets: 15, volume: 9450, best: "Squat 225×5", at: calendar.date(byAdding: .minute, value: 18 * 60 + 52, to: date)!)
            }
            return day
        }
        return TodaySnapshot(setUp: true, plate: "blue", days: days)
    }
}
