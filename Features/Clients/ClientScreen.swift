import SwiftUI
import SwiftData

/// FIT-298: a client's week: what needs you (a note opens its day to reply), the week strip, and the day picked. A
/// logged day shows what they did; today's or a later session is changed by hand as on Today, and goes straight to
/// their phone.
struct ClientScreen: View {
    let id: String
    @Environment(Account.self) private var account
    @Environment(Roster.self) private var roster
    @Query private var templates: [Template]
    @State private var day = SyncUnits.day(.now)
    /// FIT-331: the Sunday of the week shown; any week, earlier or later.
    @State private var start = Week.start(of: .now)
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

    enum Adding: String, Identifiable { case workout, run; var id: String { rawValue } }
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
                        WeekBar(start: start) { go(to: $0) }
                        strip(client)
                            .id(start)
                            .transition(.push(from: forward ? .trailing : .leading))
                    }
                    .clipped()
                    // Swipe the strip to the next or previous week, as in Calendar.
                    .simultaneousGesture(WeekBar.swipe { go(to: WeekBar.week($0, from: start)) })
                    dayCard(client)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .screenBackground()
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 24) }
        .sheet(item: $adding) { adding in
            let date = SyncUnits.date(ofKey: "plan#\(day)") ?? .now
            let latest = { roster.clients.first { $0.id == id } }
            switch adding {
            case .workout:
                ExercisePicker(title: "Add exercise") { slug in
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
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(lift.name).font(.headline)
                        Spacer(minLength: 8)
                        Text(lift.sets).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit().multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 14)
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

    /// A day's plan as it now is, sent to their phone (none clears it); kept here at once so the change shows while
    /// it goes. `done` is said once it's sent.
    private func send(_ day: String, rows: [SyncUnits.PlanRow], _ client: Roster.Client, done: String? = nil) {
        let coach = account.user?.uid ?? ""
        let key = "plan#\(day)"
        let body = rows.isEmpty ? nil : SyncUnits.encode(rows)
        var changed = client
        changed.units[key] = body
        roster.update(changed, coach: coach, names: names)
        let name = client.person.name.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "your client"
        Task {
            do {
                let kept = try await Cloud.push(key, body: body, client: id)
                if !kept { toast = Toast(text: "\(name)’s phone had a newer copy. Pull to see it.") } else if let done { toast = Toast(text: done) }
            } catch {
                toast = Toast(text: "Couldn’t send that to \(name). Try again.")
            }
        }
    }
}
