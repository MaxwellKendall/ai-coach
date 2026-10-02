import SwiftUI
import SwiftData

/// Home (FIT-19, prototype C2): swipeable progress charts over a swipeable week.
struct TodayScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var plans: [Plan]
    @Query private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query private var templates: [Template]
    @State private var adjusting: Plan?
    @State private var logging: Logging?
    @State private var live: WorkoutDraft?
    @State private var details: Rows?
    @State private var record: Rows?
    /// Set by Start on the detail sheet; workout mode opens once the sheet is gone.
    @State private var startAfterDetails: [PlannedActivity]?

    /// A day's planned workout rows, presented as a sheet.
    struct Rows: Identifiable {
        let id = UUID()
        let items: [PlannedActivity]
    }

    /// What the user tapped to log: a whole planned session, or one other planned item.
    enum Logging: Identifiable {
        case workout(WorkoutDraft, Date)
        case item(PlannedActivity)
        var id: String {
            switch self {
            case .workout(let draft, let date): "\(draft.session)\(date)"
            case .item(let item): item.id.uuidString
            }
        }
    }

    private var week: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: Week.monday(of: .now))! }
    }

    private var thisWeeksPlan: Plan? { plans.first { $0.weekStart == week[0] } }

    var body: some View {
        let byID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pages = chartPages(byID)
        let week = week
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
                    ForEach(thisWeeksPlan?.warnings ?? [], id: \.self, content: notice)
                    WeekPager(days: week, items: planned.filter { $0.date >= week[0] && $0.date < week[6] + 86_400 },
                              templates: templates, logged: Set(entries.compactMap(\.plannedRef))) { items in
                        startLogging(items)
                    } onDetails: { details = Rows(items: $0) } onRecord: { record = Rows(items: $0) }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Today")
            .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar { toolbar }
            .sheet(item: $adjusting) { plan in NavigationStack { AdjustSheet(plan: plan) } }
            .sheet(item: $details, onDismiss: {
                if let items = startAfterDetails { startLogging(items) }
                startAfterDetails = nil
            }) { rows in
                NavigationStack {
                    WorkoutDetailView(items: rows.items, session: Planner.session(rows.items, templates: templates),
                                      startTitle: rows.items.first.map { Calendar.current.isDateInToday($0.date) } == true
                                          ? "Start workout" : "Log workout") { startAfterDetails = $0 }
                }
            }
            .sheet(item: $record) { rows in NavigationStack { SessionRecordView(planned: rows.items) } }
            .fullScreenCover(item: $live) { draft in WorkoutModeView(draft: draft) }
            .sheet(item: $logging) { logging in
                NavigationStack {
                    switch logging {
                    case let .workout(draft, date): WorkoutLogView(draft: draft, date: date)
                    case let .item(item): EntryEditor(planned: item)
                    }
                }
            }
            // A new week, or a profile that just finished onboarding, gets a plan.
            .task(id: profiles.first?.isComplete) { try? Planner.ensureWeek(in: context) }
        }
    }

    private func startLogging(_ items: [PlannedActivity]) {
        guard let first = items.min(by: { $0.date < $1.date }) else { return }
        if first.kind == .workout {
            // Today's session runs in workout mode; another day's is logged at its planned time.
            let draft = WorkoutDraft(session: first.slot ?? "Workout", plan: Planner.session(items, templates: templates))
            if Calendar.current.isDateInToday(first.date) { live = draft } else { logging = .workout(draft, first.date) }
        } else {
            logging = .item(first)
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu("Plan", systemImage: "ellipsis") {
                if let plan = thisWeeksPlan {
                    Button("Adjust this week", systemImage: "slider.horizontal.3") { adjusting = plan }
                }
                Button("Regenerate this week", systemImage: "arrow.clockwise") {
                    try? Planner.generate(weekOf: .now, in: context)
                }
                .disabled(profiles.first?.isComplete != true)
            }
        }
        ToolbarItem {
            NavigationLink {
                CatalogScreen()
            } label: {
                Label("Catalog", systemImage: "books.vertical")
            }
        }
    }

    /// One lift page per 1RM goal, then protein and weekly volume, each only when there is data for it.
    private func chartPages(_ templates: [UUID: Template]) -> [ChartPage] {
        let sets = Planner.loggedSets(entries, templates: Array(templates.values))
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

extension WorkoutDraft: Identifiable {
    var id: String { session + rows.map(\.id.uuidString).joined() }
}
