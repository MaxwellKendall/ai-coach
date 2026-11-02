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
    @State private var editor: ClientDay.Editor?
    @State private var toast: Toast?

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private var client: Roster.Client? { roster.clients.first { $0.id == id } }
    private var today: String { SyncUnits.day(.now) }
    private var week: [Date] {
        let start = Week.start(of: .now)
        return (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
    }

    var body: some View {
        ScrollView {
            if let client {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(client.name).font(.display(28))
                        Text(client.week.planned == 0 ? "Nothing planned this week" : "\(client.week.done) of \(client.week.planned) this week")
                            .font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    flags(client)
                    strip(client)
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
            NavigationLink(value: DayThread.Ref(client: id, day: day)) {
                Label(replies(client, day), systemImage: "bubble.left").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
        } else if let session = editor?.session {
            // A day gone by is as it was planned; today and later can change.
            SessionList(session: session, names: names, previous: [:], checked: nil, onLoad: nil,
                        onEdit: day >= today ? { save($0, client) } : nil)
                .padding(.horizontal, 20).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            if day < today { Text("Not logged").font(.subheadline).foregroundStyle(Color.inkMuted).padding(.horizontal, 4) }
        } else {
            Text("Rest day").font(.title3.weight(.bold))
                .padding(20).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
        }
    }

    private func replies(_ client: Roster.Client, _ day: String) -> String {
        let count = client.comments.filter { $0.day == day }.count
        return count == 0 ? "Reply" : count == 1 ? "1 reply" : "\(count) replies"
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
