import SwiftUI
import SwiftData

/// Home (FIT-19, prototype C2): swipeable progress charts over a swipeable week.
struct TodayScreen: View {
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query private var templates: [Template]

    var body: some View {
        let byID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pages = chartPages(byID)
        let week = (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: Week.monday(of: .now))! }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if pages.isEmpty {
                        ContentUnavailableView("No progress yet", systemImage: "chart.line.uptrend.xyaxis",
                                               description: Text("Log a workout or meal to see your trends here."))
                            .frame(height: 250)
                    } else {
                        ChartCarousel(pages: pages)
                    }
                    WeekPager(days: week, items: planned.filter { $0.date >= week[0] && $0.date < week[6] + 86_400 },
                              names: byID.mapValues(\.name))
                }
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Today")
            .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                NavigationLink {
                    CatalogScreen()
                } label: {
                    Label("Catalog", systemImage: "books.vertical")
                }
            }
        }
    }

    /// One lift page per 1RM goal, then protein and weekly volume, each only when there is data for it.
    private func chartPages(_ templates: [UUID: Template]) -> [ChartPage] {
        let sets = entries.filter { $0.kind == .workout }.compactMap { entry -> LoggedSet? in
            guard let template = entry.templateRef.flatMap({ templates[$0] }) else { return nil }
            return LoggedSet(date: entry.timestamp, exercise: template.slug,
                             pattern: template.values("movement_pattern").first, measurements: entry.measurements)
        }
        let names = Dictionary(templates.values.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        var pages: [ChartPage] = goals.filter { $0.metric.hasSuffix(".1rm_lb") }.compactMap { goal in
            let slug = String(goal.metric.dropLast(".1rm_lb".count))
            let trend = Training.estimated1RMTrend(sets, exercise: slug)
            return trend.isEmpty ? nil : .lift(name: names[slug] ?? Goal.label(goal.metric), trend: trend, goal: goal.target)
        }
        let protein = Daily.totals(entries.map { ($0.timestamp, $0.measurements) }, metric: "protein_g").suffix(14)
        if !protein.isEmpty {
            pages.append(.daily(name: "Protein", unit: "g", values: Array(protein),
                                goal: goals.first { $0.metric == "protein_g" }?.target))
        }
        if let last = sets.last?.date {
            pages.append(.volume(setsByPattern: Training.setsByPattern(sets, endingOn: last), endingOn: last))
        }
        return pages
    }
}
