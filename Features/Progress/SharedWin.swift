import Foundation

/// FIT-107: a win as it's saved for its page (infra/lambda/sharePages.ts reads it). With weights hidden, none are
/// sent at all: a personal best goes as percent of the last best, a milestone as percent of the goal.
enum SharedWin {
    static func payload(_ win: WinItem, style: CardStyle, showNumbers: Bool) -> [String: Any] {
        let words = WinWords(win, showNumbers: showNumbers)
        var payload: [String: Any] = [
            "date": win.date.formatted(.iso8601.year().month().day()),
            "showNumbers": showNumbers,
            "style": style == .paper ? "paper" : "dark",
        ]
        switch win.kind {
        case .pr:
            payload["kind"] = "pr"
            // "Bench press max" reads as a lift on the page: "Max set a bench press best".
            payload["metric"] = words.option?.liftName ?? win.metric
            payload["unit"] = win.unit
            if showNumbers {
                payload["value"] = win.value
                if let previous = win.previous { payload["previous"] = previous }
                payload["trend"] = win.trend
            } else {
                let base = win.previous ?? win.value
                let percent = { (value: Double) in (value / max(base, 1) * 1000).rounded() / 10 }
                payload["value"] = percent(win.value)
                payload["previous"] = 100.0
                payload["trend"] = win.trend.map(percent)
                payload["unit"] = "%"
            }
        case .milestone:
            payload["kind"] = "milestone"
            payload["metric"] = words.shortName
            payload["unit"] = showNumbers ? win.unit : "%"
            payload["percent"] = win.percent ?? 0
            payload["value"] = showNumbers ? win.value : Double(win.percent ?? 0)
            if let target = showNumbers ? win.target : 100 { payload["target"] = target }
        case .streak:
            payload["kind"] = "streak"
            payload["metric"] = "Training"
            payload["unit"] = "weeks"
            payload["value"] = win.value
        }
        return payload
    }
}
