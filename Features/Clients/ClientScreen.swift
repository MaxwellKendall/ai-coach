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
                    }
                    flags(client)
                    VStack(spacing: 12) {
                        weekBar
                        strip(client)
                            .id(start)
                            .transition(.push(from: forward ? .trailing : .leading))
                    }
                    .clipped()
                    // Swipe the strip to the next or previous week, as in Calendar.
                    .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height), abs(drag.translation.width) > 40 else { return }
                        go(drag.translation.width < 0 ? 1 : -1)
                    })
                    dayCard(client)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .screenBackground()
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 24) }
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

    /// The week's dates, ‹ ›, and "This Week" to come back, as Calendar's week view has them.
    private var weekBar: some View {
        HStack(spacing: 4) {
            Text(thisWeek ? "This week" : Self.range(week[0], week[6])).font(.headline).contentTransition(.numericText())
            Spacer()
            if !thisWeek {
                Button("This Week") { go(to: Week.start(of: .now)) }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Plate.current.mark)
                    .padding(.trailing, 6)
            }
            ForEach([-1, 1], id: \.self) { step in
                Button { go(step) } label: {
                    Image(systemName: step < 0 ? "chevron.left" : "chevron.right").font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36).background(Color.fill, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step < 0 ? "Previous week" : "Next week")
            }
        }
    }

    /// "Nov 2 – 8", or "Oct 26 – Nov 1" across a month.
    static func range(_ first: Date, _ last: Date) -> String {
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
    }

    private func go(_ weeks: Int) {
        go(to: Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: start)!)
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
            // A day gone by is as it was planned; today and later can change.
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
            message(client)
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

    /// The day as changed, sent to their phone; kept here at once so the change shows while it goes.
    private func save(_ session: SessionPlan, _ client: Roster.Client) {
        guard let editor else { return }
        let coach = account.user?.uid ?? ""
        let rows = editor.save(session)
        let key = "plan#\(day)"
        let body = rows.isEmpty ? nil : SyncUnits.encode(rows)
        var changed = client
        changed.units[key] = body
        roster.update(changed, coach: coach, names: names)
        let name = client.person.name.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "your client"
        Task {
            do {
                let kept = try await Cloud.push(key, body: body, client: id)
                if !kept { toast = Toast(text: "\(name)’s phone had a newer copy. Pull to see it.") }
            } catch {
                toast = Toast(text: "Couldn’t send that to \(name). Try again.")
            }
        }
    }
}
