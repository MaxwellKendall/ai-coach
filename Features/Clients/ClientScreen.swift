import SwiftUI
import SwiftData

/// FIT-298: a client's week: what needs you (a note opens its day to reply), the week strip, and the day picked. A
/// logged day shows what they did; today's or a later session is changed by hand as on Today, and goes straight to
/// their phone.
struct ClientScreen: View {
    /// FIT-338: a client opened on a given day, from a coach's notification.
    struct Opening: Hashable { var client: String; var day: String? }

    let id: String
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(Roster.self) private var roster
    @Query private var templates: [Template]
    @State private var day: String
    /// FIT-331: the Sunday of the week shown; any week, earlier or later.
    @State private var start: Date

    init(id: String, day: String? = nil) {
        self.id = id
        let opened = day ?? SyncUnits.day(.now)
        _day = State(initialValue: opened)
        _start = State(initialValue: Week.start(of: SyncUnits.date(ofKey: "plan#\(opened)") ?? .now))
    }
    /// Which way the last week change went, so the strip slides the right way.
    @State private var forward = true
    @State private var editor: ClientDay.Editor?
    /// The day `editor` was made for: until it catches up with `day`, the old day's session isn't shown.
    @State private var editorDay: String?
    @State private var toast: Toast?
    /// FIT-335: what's being added to the day, and where its session is going.
    @State private var adding: Adding?
    @State private var dated: Dated?
    @State private var clearing = false

    /// FIT-336: a sheet for the week, and a change to it waiting on "Replace?" when it would overwrite planned days.
    @State private var weekSheet: WeekSheet?
    @State private var pending: Pending?
    /// FIT-337: the logged lift being corrected.
    @State private var correcting: Correcting?

    struct Correcting: Identifiable { var slug: String; var name: String; var id: String { slug } }

    enum Adding: String, Identifiable { case workout, run; var id: String { rawValue } }
    enum WeekSheet: String, Identifiable { case repeating, program; var id: String { rawValue } }
    struct Pending { var days: [String: [SyncUnits.PlanRow]]; var replacing: Int; var done: String }
    enum Dated: String, Identifiable { case move, copy; var id: String { rawValue } }

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private var client: Roster.Client? { roster.clients.first { $0.id == id } }
    private var today: String { SyncUnits.day(.now) }
    private var thisWeek: Bool { start == Week.start(of: .now) }
    private var week: [Date] { (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! } }

    var body: some View {
        ScrollView {
            if let client {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Avatar(client: client, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name).font(.display(28))
                            Text(summary(client)).font(.subheadline).foregroundStyle(Color.inkMuted)
                        }
                        Spacer(minLength: 0)
                        // FIT-337: their goals, lifts, weeks, check-ins and profile.
                        NavigationLink(value: ClientProgressScreen.Ref(client: id)) {
                            Image(systemName: "chart.line.uptrend.xyaxis").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                                .frame(width: 44, height: 44).background(Color.fill, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(client.name)’s progress")
                        // FIT-331: every message with them, all days, in one conversation.
                        NavigationLink(value: DayThread.Ref(client: id, day: today)) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                                .frame(width: 44, height: 44).background(Color.fill, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Messages with \(client.name)")
                    }
                    flags(client)
                    VStack(spacing: 12) {
                        // FIT-363: the week's actions are in the day's ⋯, so the bar shows only for another week.
                        if start != Week.start(of: .now) { WeekBar(start: start, go: { go(to: $0) }) }
                        strip(client)
                            .id(start)
                            .motionTransition(.push(from: forward ? .trailing : .leading))
                    }
                    .clipped()
                    // Swipe the strip to the next or previous week, as in Calendar.
                    .simultaneousGesture(WeekPaging.swipe { go(to: WeekPaging.week($0, from: start)) })
                    dayCard(client)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .screenBackground()
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 24) }
        // FIT-339: removed (from their progress screen): back to the list.
        .onChange(of: client == nil) { _, gone in if gone && roster.loaded { dismiss() } }
        .sheet(item: $adding) { adding in
            let date = SyncUnits.date(ofKey: "plan#\(day)") ?? .now
            let latest = { roster.clients.first { $0.id == id } }
            switch adding {
            case .workout:
                let units = latest()?.units ?? [:]
                ExercisePicker(title: "Add exercise", excluding: Set(ClientDay.plan(units, day).compactMap(\.template)),
                               settings: ClientDay.settings(units), uses: ClientDay.uses(units)) { slug in
                    guard let client = latest() else { return }
                    send(day, rows: ClientDay.exercise(slug, on: date, after: ClientDay.plan(client.units, day)), client)
                }
            case .run:
                PlanRunSheet(day: day) { kind, miles in
                    guard let client = latest() else { return }
                    send(day, rows: ClientDay.run(kind, miles: miles, on: date, after: ClientDay.plan(client.units, day)), client,
                         done: "Run added")
                }
            }
        }
        .sheet(item: $correcting) { lift in
            let log = client.map { ClientDay.log($0.units, day) } ?? []
            CorrectSetsSheet(name: lift.name, sets: log.filter { $0.kind == .workout && $0.template == lift.slug }.sorted { $0.at < $1.at }) { fixes in
                guard let client = roster.clients.first(where: { $0.id == id }) else { return }
                var rows = ClientDay.log(client.units, day)
                for (set, fix) in fixes { rows = ClientDay.fixed(rows, id: set, fix) }
                sendLog(day, rows: rows, client)
            }
        }
        .sheet(item: $weekSheet) { sheet in
            switch sheet {
            case .repeating:
                RepeatWeekSheet { weeks, progress in
                    guard let client = roster.clients.first(where: { $0.id == id }) else { return }
                    let week = ClientWeek.days(client.units, sunday: start)
                    propose(ClientWeek.repeated(week, weeks: weeks, progress: progress), client,
                            done: "Repeated for \(weeks) week\(weeks == 1 ? "" : "s")")
                }
            case .program:
                StartProgramSheet(from: max(Calendar.current.startOfDay(for: .now), start)) { ready, from in
                    guard let client = roster.clients.first(where: { $0.id == id }) else { return }
                    let profile = client.units["profile"].flatMap { try? SyncUnits.decode(SyncUnits.ProfileBody.self, $0) }
                    let logs = client.units.keys.filter { $0.hasPrefix("log#") }.flatMap { ClientDay.log(client.units, String($0.dropFirst(4))) }
                    propose(ClientWeek.program(ready, from: from, profile: profile, logs: logs, templates: templates), client,
                            done: "\(ready.name) starts \(Self.dayTitle(SyncUnits.day(from)))")
                }
            }
        }
        .confirmationDialog(pending.map { "Replace \($0.replacing) planned day\($0.replacing == 1 ? "" : "s")?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let pending, let client = roster.clients.first(where: { $0.id == id }) { sendAll(pending.days, client, done: pending.done) }
                pending = nil
            }
        } message: {
            Text("Those days already have a session; this puts the new one in its place.")
        }
        .sheet(item: $dated) { dated in
            PlanDaySheet(title: dated == .move ? "Move to" : "Copy to", from: day) { target in
                guard let client = roster.clients.first(where: { $0.id == id }) else { return }
                place(client, at: target, move: dated == .move)
            }
        }
        .animation(.snappy, value: toast)
        .task(id: "\(day) \(client?.units["plan#\(day)"]?.hashValue ?? 0)") {
            editor = client.map { ClientDay.Editor(ClientDay.plan($0.units, day), templates: templates) }
            editorDay = day
        }
    }

    @ViewBuilder private func flags(_ client: Roster.Client) -> some View {
        if !client.week.flags.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(client.week.flags.enumerated()), id: \.offset) { index, flag in
                    let row = HStack(spacing: 12) {
                        FlagDot(kind: flag.kind)
                        Text(flag.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        if flag.day != nil { Text("Reply").font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark) }
                    }
                    .padding(.vertical, 14).contentShape(.rect)
                    if let day = flag.day {
                        NavigationLink(value: DayThread.Ref(client: id, day: day)) { row }.buttonStyle(.plain)
                    } else {
                        row
                    }
                    // FIT-362: from what hurts to the session it changes.
                    if flag.kind == .pain, let next = ClientDay.nextSession(client.units, from: today) {
                        Button { open(next) } label: {
                            Label("Change \(Self.weekday(next)) session", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 22).padding(.bottom, 14)
                    }
                    if index < client.week.flags.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .cardBackground()
        }
    }

    /// "3 of 4 this week", or the week shown's own count: "Nov 2 – 8 · 2 of 3 done".
    private func summary(_ client: Roster.Client) -> String {
        if thisWeek {
            return client.week.planned == 0 ? "Nothing planned this week" : "\(client.week.done) of \(client.week.planned) this week"
        }
        let days = week.map { SyncUnits.day($0) }
        let done = days.filter { ClientDay.trained(client.units, $0) }.count
        let planned = days.filter { ClientDay.trained(client.units, $0) || ClientDay.planned(client.units, $0) }.count
        return planned == 0 ? "Nothing planned" : "\(done) of \(planned) done"
    }

    /// FIT-362: a day in any week, opened as if picked on its strip.
    private func open(_ key: String) {
        guard let date = SyncUnits.date(ofKey: "plan#\(key)") else { return }
        let sunday = Week.start(of: date)
        forward = sunday >= start
        withAnimation(.snappy) {
            start = sunday
            day = key
        }
    }

    /// "Thursday", or "today" / "tomorrow".
    private static func weekday(_ key: String) -> String {
        guard let date = SyncUnits.date(ofKey: "plan#\(key)") else { return "next" }
        if Calendar.current.isDateInToday(date) { return "today's" }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow's" }
        return date.formatted(.dateTime.weekday(.wide)) + "’s"
    }

    /// To another week, on the same weekday as the day picked; on this week, today.
    private func go(to sunday: Date) {
        guard sunday != start else { return }
        let picked = week.firstIndex { SyncUnits.day($0) == day } ?? 0
        forward = sunday > start
        withAnimation(.snappy) {
            start = sunday
            day = sunday == Week.start(of: .now) ? today : SyncUnits.day(Calendar.current.date(byAdding: .day, value: picked, to: sunday)!)
        }
    }

    /// Sunday to Saturday, as on Today: a dot under a day they trained, a ring under one still to do.
    private func strip(_ client: Roster.Client) -> some View {
        HStack(spacing: 0) {
            ForEach(week, id: \.self) { date in
                let key = SyncUnits.day(date)
                Button { withAnimation(.snappy) { day = key } } label: {
                    VStack(spacing: 6) {
                        Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption).foregroundStyle(Color.inkMuted)
                        Text(date.formatted(.dateTime.day())).font(.body.weight(key == day ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(key == day ? Color.surface : key == today ? Plate.current.mark : Color.ink)
                            .frame(width: 34, height: 34)
                            .background(key == day ? Color.ink : .clear, in: .circle)
                        Group {
                            if ClientDay.trained(client.units, key) {
                                Circle().fill(Color.ink)
                            } else if ClientDay.planned(client.units, key) {
                                Circle().strokeBorder(Color.inkFaint, lineWidth: 1.5)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func dayCard(_ client: Roster.Client) -> some View {
        let log = ClientDay.log(client.units, day)
        let lifts = ClientDay.lifts(log, names: names)
        if !lifts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lifts.enumerated()), id: \.offset) { index, lift in
                    // FIT-337: a set logged wrong is corrected here, as on the dashboard (FIT-200).
                    Button { correcting = Correcting(slug: lift.slug, name: lift.name) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(lift.name).font(.headline)
                            Spacer(minLength: 8)
                            Text(lift.sets).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit().multilineTextAlignment(.trailing)
                            Image(systemName: "pencil").font(.footnote).foregroundStyle(Color.inkFaint)
                        }
                        .padding(.vertical, 14).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Correct what was logged")
                    if index < lifts.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 20)
            .cardBackground()
            message(client)
        } else if editorDay != day {
            Color.clear.frame(height: 80)
        } else if let session = editor?.session {
            // A day gone by is as it was planned; today and later can change, and move, copy or clear (FIT-335).
            if day >= today { dayBar(client) }
            SessionList(session: session, names: names, previous: [:], checked: nil,
                        onLoad: day >= today ? { changeLoad($0, by: $1, in: session, client) } : nil,
                        onEdit: day >= today ? { save($0, client) } : nil)
                .padding(.horizontal, 20).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            if day < today { Text("Not logged").font(.subheadline).foregroundStyle(Color.inkMuted).padding(.horizontal, 4) }
            message(client)
        } else {
            Text("Rest day").font(.title3.weight(.bold))
                .padding(20).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
            // FIT-335: a coach can plan any day from today on, from nothing.
            if day >= today {
                HStack(spacing: 10) {
                    Button { adding = .workout } label: { Label("Workout", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.primary)
                    Button { adding = .run } label: { Label("Run", systemImage: "figure.run").frame(maxWidth: .infinity) }.buttonStyle(.secondary)
                }
            }
            message(client)
        }
    }

    /// FIT-335: what can be done to the whole day: move it, copy it, add a run, or clear it.
    private func dayBar(_ client: Roster.Client) -> some View {
        HStack {
            Text(Self.dayTitle(day)).font(.headline)
            Spacer()
            Menu {
                Button("Move to Another Day", systemImage: "calendar") { dated = .move }
                Button("Copy to Another Day", systemImage: "plus.square.on.square") { dated = .copy }
                Button("Add a Run", systemImage: "figure.run") { adding = .run }
                Divider()
                Button("Clear Day", systemImage: "trash", role: .destructive) { clearing = true }
                // FIT-363: the week's actions here too, so there's one ⋯.
                Section("This Week") { weekActions(client) }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Color.inkMuted)
                    .frame(width: 44, height: 32).background(Color.fill, in: .capsule)
            }
            .accessibilityLabel("Change \(Self.dayTitle(day))")
        }
        .padding(.horizontal, 4)
        .confirmationDialog("Clear \(Self.dayTitle(day))?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear Day", role: .destructive) { send(day, rows: [], client, done: "Cleared \(Self.dayTitle(day))") }
        } message: {
            Text("Its session comes off their plan.")
        }
    }

    static func dayTitle(_ day: String) -> String {
        let date = SyncUnits.date(ofKey: "plan#\(day)") ?? .now
        return Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Move or copy the day's session to `target`, after anything already planned there.
    private func place(_ client: Roster.Client, at target: Date, move: Bool) {
        let key = SyncUnits.day(target)
        guard key != day else { return }
        let rows = ClientDay.plan(client.units, day)
        let landed = ClientDay.appended(ClientDay.shifted(rows, to: target, fresh: !move), to: ClientDay.plan(client.units, key))
        let name = Self.dayTitle(key)
        send(key, rows: landed, client, done: move ? "Moved to \(name)" : "Copied to \(name)")
        if move {
            // The client's latest, with the copy just made, so the second change keeps the first.
            send(day, rows: [], roster.clients.first { $0.id == id } ?? client)
        }
    }

    /// FIT-331: the coach writes to a client on any day, logged or not: the day's thread, which their Today shows.
    private func message(_ client: Roster.Client) -> some View {
        let count = client.comments.filter { $0.day == day }.count
        return NavigationLink(value: DayThread.Ref(client: id, day: day)) {
            Label(count == 0 ? "Message" : count == 1 ? "1 message" : "\(count) messages", systemImage: "bubble.left")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.secondary)
    }

    /// FIT-331: a lift's working weight ±5 lb, every working set of it, as Today's load does for one's own session.
    private func changeLoad(_ exercise: String, by step: Double, in session: SessionPlan, _ client: Roster.Client) {
        var changed = session
        for (b, block) in session.blocks.enumerated() {
            for (m, movement) in block.movements.enumerated() where movement.exercise == exercise {
                guard let first = movement.sets.firstIndex(where: { !$0.isWarmup }), let load = SessionList.load(movement) else { continue }
                let metric = movement.working.first?.value("load_lb") != nil ? "load_lb" : "load_lb_hand"
                changed.set(metric, to: max(0, load + step), block: b, movement: m, set: first, remaining: true)
            }
        }
        save(changed, client)
    }

    /// The day as changed by hand, sent to their phone.
    private func save(_ session: SessionPlan, _ client: Roster.Client) {
        guard let editor else { return }
        send(day, rows: editor.save(session), client)
    }

    /// A day's plan as it now is, sent to their phone (none clears it). `done` is said once it's sent.
    private func send(_ day: String, rows: [SyncUnits.PlanRow], _ client: Roster.Client, done: String? = nil) {
        sendAll([day: rows], client, done: done)
    }

    /// Days' plans as they now are, kept here at once so the change shows while they go, then sent to their phone one
    /// by one.
    private func sendAll(_ days: [String: [SyncUnits.PlanRow]], _ client: Roster.Client, done: String? = nil) {
        let coach = account.user?.uid ?? ""
        let bodies = days.map { (key: "plan#\($0.key)", body: $0.value.isEmpty ? nil : SyncUnits.encode($0.value)) }
        var changed = client
        for unit in bodies { changed.units[unit.key] = unit.body }
        roster.update(changed, coach: coach, names: names)
        let name = client.person.name.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "your client"
        Task {
            do {
                var kept = true
                for unit in bodies.sorted(by: { $0.key < $1.key }) { kept = try await Cloud.push(unit.key, body: unit.body, client: id) && kept }
                if !kept { toast = Toast(text: "\(name)’s phone had a newer copy. Pull to see it.") } else if let done { toast = Toast(text: done) }
            } catch {
                toast = Toast(text: "Couldn’t send that to \(name). Try again.")
            }
        }
    }

    /// FIT-337: a day's log as corrected, sent to their phone.
    private func sendLog(_ day: String, rows: [SyncUnits.LogRow], _ client: Roster.Client) {
        let key = "log#\(day)"
        let body = rows.isEmpty ? nil : SyncUnits.encode(rows)
        var changed = client
        changed.units[key] = body
        roster.update(changed, coach: account.user?.uid ?? "", names: names)
        let name = client.person.name.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "your client"
        Task {
            do {
                let kept = try await Cloud.push(key, body: body, client: id)
                toast = Toast(text: kept ? "Corrected" : "\(name)’s phone had a newer copy. Pull to see it.")
            } catch {
                toast = Toast(text: "Couldn’t send that to \(name). Try again.")
            }
        }
    }

    /// FIT-336: what can be done to the whole week shown, from today on.
    @ViewBuilder private func weekActions(_ client: Roster.Client) -> some View {
        let week = ClientWeek.days(client.units, sunday: start)
        if !week.isEmpty {
            Button("Copy to Next Week", systemImage: "arrow.right.square") {
                propose(ClientWeek.repeated(week, weeks: 1, progress: false), client, done: "Copied to next week")
            }
            Button("Copy to Next Week, +5 lb", systemImage: "arrow.up.right.square") {
                propose(ClientWeek.repeated(week, weeks: 1, progress: true), client, done: "Copied to next week, 5 lb heavier")
            }
            Button("Repeat for More Weeks…", systemImage: "repeat") { weekSheet = .repeating }
            Button("Make It a Deload Week", systemImage: "arrow.down.right.circle") {
                let days = week.filter { $0.key >= today }.mapValues(ClientWeek.deloaded)
                sendAll(days, client, done: "Deload week")
            }
            .disabled(!week.keys.contains { $0 >= today })
        }
        Button("Start a Program…", systemImage: "list.bullet.rectangle") { weekSheet = .program }
        if week.keys.contains(where: { $0 >= today }) {
            Divider()
            Button("Clear This Week", systemImage: "trash", role: .destructive) {
                sendAll(week.filter { $0.key >= today }.mapValues { _ in [] }, client, done: "Week cleared")
            }
        }
    }

    /// New plans for days, sent at once, or after "Replace?" when some of those days already have a session.
    private func propose(_ days: [String: [SyncUnits.PlanRow]], _ client: Roster.Client, done: String) {
        // Only today and later: what's gone by is as it was.
        let days = days.filter { $0.key >= today }
        guard !days.isEmpty else { toast = Toast(text: "Those days have gone by"); return }
        let replacing = days.keys.filter { !ClientDay.plan(client.units, $0).isEmpty }.count
        if replacing == 0 { sendAll(days, client, done: done) } else { pending = Pending(days: days, replacing: replacing, done: done) }
    }
}
