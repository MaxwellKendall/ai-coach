import SwiftUI
import SwiftData

/// FIT-113: "Train with me". The sharer sends a planned day as a link (with their first group's invite, so on the day
/// they see each other live); the friend gets the same session on that day with weights from their own lifts.
@MainActor enum TrainWithFriend {
    static func link(for plan: DayCard.Planned, templates: [Template]) async throws -> SharedLink {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let workouts = plan.items.sorted { $0.date < $1.date }.map {
            PlannedWorkout(date: $0.date, session: $0.slot ?? "", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                           targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note)
        }
        var invite: String?
        if let group = try? await Cloud.myGroups().first { invite = try? await Cloud.group(group.groupId)?.inviteCode }
        // The friend's weights come from their own lifts, so the sharer's aren't sent.
        let shared = SharedSession.make(title: plan.title, date: plan.start, time: plan.start.formatted(date: .omitted, time: .shortened),
                                        workouts: workouts, names: names, showNumbers: false, invite: invite)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any] ?? [:]
        let share = try await Cloud.createShare(kind: "session", payload: payload)
        guard let url = URL(string: share.url) else { throw URLError(.badURL) }
        // The card is the link's preview in iMessage, so it's uploaded before the link is shared.
        let card = PlanCard.session(shared, link: ShareLinks.short(url)).image()
        if let png = card?.pngData() { try? await Cloud.uploadCard(png, for: share.id) }
        return SharedLink(url: url, title: "Train with me: \(plan.title), \(plan.start.formatted(.dateTime.weekday(.wide)))", image: card)
    }
}

/// Opened from a shared session's link: what it is, with the friend's own weights, and Add. Principle 7: nothing
/// is planned until they say so.
struct JoinSessionSheet: View {
    let id: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @State private var loaded: Loaded?
    @State private var failure: String?
    @State private var working = false

    struct Loaded {
        var who: String
        var shared: SharedSession.Shared
        var date: Date
        var workouts: [PlannedWorkout]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loaded { content(loaded) } else if let failure {
                    ContentUnavailableView("Can’t open this session", systemImage: "calendar.badge.exclamationmark", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(loaded.map { "Train with \($0.who)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await load() }
    }

    private func content(_ loaded: Loaded) -> some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let past = loaded.date < Calendar.current.startOfDay(for: .now)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loaded.shared.title).font(.title2.weight(.bold))
                    Text([loaded.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()), loaded.shared.time, loaded.shared.minutes.map { "~\($0) min" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(Array(loaded.workouts.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(names[row.exercise] ?? row.exercise)
                        Spacer()
                        Text(Self.targets(row)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } footer: {
                Text(loaded.shared.invite == nil ? "Weights are from your own lifts. Any left blank, you fill in as you go."
                     : "Weights are from your own lifts. You’ll join \(loaded.who)’s group, so you can see each other train live.")
            }
            Section {
                Button(past ? "This session has passed" : "Add to \(loaded.date.formatted(.dateTime.weekday(.wide)))") { add(loaded) }
                    .bold().frame(maxWidth: .infinity).disabled(past || working)
            }
        }
    }

    /// "4 × 5 · 140 lb".
    static func targets(_ row: PlannedWorkout) -> String {
        let sets = Int(row.target("sets") ?? 1)
        let each = row.target("reps").map { "\(Int($0))" } ?? row.target("duration_s").map { "\(Int($0)) s" } ?? ""
        let load = row.target("load_lb").map { " · \(Coach.number($0)) lb" } ?? ""
        return "\(sets) × \(each)\(load)"
    }

    private func load() async {
        do {
            guard let item = try await Cloud.share(id), item.kind == "session",
                  let shared = try? JSONDecoder().decode(SharedSession.Shared.self, from: Data(item.payload.utf8)),
                  var date = SharedSession.date(shared.date) else {
                failure = "Whoever shared it may have stopped sharing."
                return
            }
            // On the sharer's time of day, when there is one.
            if let time = shared.time.flatMap(Self.time) { date = Calendar.current.date(byAdding: time, to: date) ?? date }
            let history = Planner.loggedSets(entries, templates: templates)
            let workouts = SharedSession.workouts(shared, history: history).map { row in
                var row = row
                row.date = date
                return row
            }
            loaded = Loaded(who: item.name?.split(separator: " ").first.map(String.init) ?? "a friend", shared: shared, date: date,
                            workouts: workouts)
        } catch {
            failure = "Check your connection and try again."
        }
    }

    /// "6:00 AM" (as the sharer's phone wrote it) as hours and minutes.
    static func time(_ text: String) -> DateComponents? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        guard let date = formatter.date(from: text.replacingOccurrences(of: "\u{202F}", with: " ")) else { return nil }
        return Calendar.current.dateComponents([.hour, .minute], from: date)
    }

    /// The session goes on its day, pinned so a regenerated week keeps it, in place of what was planned that day.
    private func add(_ loaded: Loaded) {
        working = true
        Task {
            defer { working = false }
            do {
                guard let plan = try Planner.plan(weekOf: loaded.date, in: context) ?? Planner.generate(weekOf: loaded.date, in: context) else {
                    failure = "Finish setting up, then open the link again."
                    return
                }
                let day = plan.items.filter { $0.kind == .workout && Calendar.current.isDate($0.date, inSameDayAs: loaded.date) }
                let rows: [PlannedActivity]
                if day.isEmpty {
                    let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
                    rows = loaded.workouts.enumerated().map { Planner.activity($0.element, order: $0.offset, ids: ids) }
                    plan.items += rows
                } else {
                    rows = try Planner.replace(day, with: loaded.workouts, templates: templates, in: context)
                }
                for row in rows { row.pinned = true }
                plan.updatedAt = .now
                try context.save()
                if let invite = loaded.shared.invite { _ = try? await Cloud.join(code: invite) }
                dismiss()
            } catch {
                failure = "Couldn’t add it. Try again."
            }
        }
    }
}

/// A shared session's id, for presenting it.
struct SessionRef: Identifiable {
    let id: String
}
