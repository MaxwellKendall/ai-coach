import SwiftUI
import WidgetKit

/// TKL-802: the "today's workout" widget, on the home screen (small, medium, large) and the Lock Screen (rectangular,
/// inline). It reads the snapshot the app writes to the App Group (Core/Widget/TodaySnapshot.swift) and makes one entry
/// per midnight from it, so the next day shows up without the app opening.
struct TodayWidget: Widget {
    /// TodayWidget.kind in the app.
    let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(content: entry.content, plate: entry.plate, family: entry.family)
                .containerBackground(for: .widget) { TodayTone(plate: entry.plate).surface }
                .widgetURL(TodaySnapshot.Link.today.url)
        }
        .configurationDisplayName("Today's workout")
        .description("Today's session, your week and your usual time. Start opens the live workout.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let content: TodaySnapshot.Content
    let plate: String
    let family: WidgetFamily
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, content: TodayWidgetSample.content(.workout), plate: "blue", family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        // The gallery shows the sample day until the app has written one.
        let snapshot = TodaySnapshot.read()
        let content = snapshot.map { $0.content(on: .now) } ?? TodayWidgetSample.content(.workout)
        completion(TodayEntry(date: .now, content: context.isPreview && snapshot == nil ? TodayWidgetSample.content(.workout) : content,
                              plate: snapshot?.plate ?? "blue", family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = TodaySnapshot.read()
        let now = Date.now
        let dates = snapshot?.timeline(from: now) ?? [now]
        let entries = dates.map {
            TodayEntry(date: $0, content: TodaySnapshot.content(snapshot, on: $0), plate: snapshot?.plate ?? "blue", family: context.family)
        }
        // With no snapshot yet, look again tomorrow; the app reloads the widget as soon as it writes one.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        completion(Timeline(entries: entries, policy: snapshot == nil ? .after(tomorrow) : .atEnd))
    }
}
