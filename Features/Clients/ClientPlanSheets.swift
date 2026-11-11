import SwiftUI
import SwiftData

/// FIT-335: a run for a client's day: its kind, as the program names them, and its distance in miles.
struct PlanRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let day: String
    let onAdd: (_ kind: String, _ miles: Double) -> Void
    @State private var kind = "easy"
    @State private var miles = 3.0

    static let kinds = [("easy", "Easy"), ("long", "Long"), ("tempo", "Tempo"), ("intervals", "Intervals")]

    // FIT-367: a standard sheet: the title inline, Cancel and Add in the bar, the choices as a form.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("\(Coach.number(miles)) mi", value: $miles, in: 0.5...30, step: 0.5).monospacedDigit()
                } footer: {
                    Text(Coach.run(kind: kind))
                }
            }
            .navigationTitle(ClientScreen.dayTitle(day) == "Today" ? "Run Today" : "Run on \(ClientScreen.dayTitle(day))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(kind, miles)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        // Opaque, so the client's day behind doesn't show through the form.
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// FIT-335: the day a client's session moves or is copied to: any day from today on, as Calendar picks one.
struct PlanDaySheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let from: String
    let onPick: (Date) -> Void
    @State private var date: Date

    init(title: String, from: String, onPick: @escaping (Date) -> Void) {
        self.title = title
        self.from = from
        self.onPick = onPick
        let start = SyncUnits.date(ofKey: "plan#\(from)") ?? .now
        _date = State(initialValue: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    // FIT-367: a standard sheet, as Calendar's date pickers are: the title inline, Cancel and the action in the bar.
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title.hasPrefix("Move") ? "Move" : "Copy") {
                        onPick(date)
                        dismiss()
                    }
                    .disabled(SyncUnits.day(date) == from)
                }
            }
        }
        .presentationDetents([.height(500), .large])
        .presentationBackground(Color(.systemBackground))
    }
}

/// FIT-336: the week shown, repeated for some weeks, with or without 5 lb more a week on the main lifts.
struct RepeatWeekSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onRepeat: (_ weeks: Int, _ progress: Bool) -> Void
    @State private var weeks = 3
    @State private var progress = true

    // FIT-367: a standard sheet: the title inline, Cancel and Repeat in the bar, the choices as a form.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(weeks == 1 ? "1 week" : "\(weeks) weeks", value: $weeks, in: 1...12).monospacedDigit()
                    Toggle("5 lb more each week on the main lifts", isOn: $progress)
                }
            }
            .navigationTitle("Repeat This Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repeat") {
                        onRepeat(weeks, progress)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        // Opaque, so the client's day behind doesn't show through the form.
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// FIT-336: a ready-made program for the client (programs.json), every week of it planned from a start day.
struct StartProgramSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onStart: (ReadyProgram, Date) -> Void
    @State private var picked: ReadyProgram?
    @State private var from: Date

    init(from: Date, onStart: @escaping (ReadyProgram, Date) -> Void) {
        self.onStart = onStart
        _from = State(initialValue: from)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Starts", selection: $from, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                }
                Section {
                    ForEach(ReadyProgram.all) { ready in
                        Button { picked = ready } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ready.name).font(.headline).foregroundStyle(Color.ink)
                                    Text("\(ready.weeks) weeks · \(ready.days.map(String.init).joined(separator: " or ")) days · \(ready.minutes) min")
                                        .font(.subheadline).foregroundStyle(Color.inkMuted)
                                }
                                Spacer()
                                if picked?.id == ready.id { Image(systemName: "checkmark").foregroundStyle(Plate.current.mark) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Every week is planned now, from what they've logged so far; change any day after.")
                }
            }
            .navigationTitle("Start a Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        if let picked { onStart(picked, from) }
                        dismiss()
                    }
                    .disabled(picked == nil)
                }
            }
        }
    }
}

/// FIT-337: a lift's logged sets, corrected by the coach (the dashboard's FIT-200 corrections): weight, reps and RPE
/// for each, typed; empty leaves a value out.
struct CorrectSetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let sets: [SyncUnits.LogRow]
    let onSave: ([UUID: ClientDay.SetFix]) -> Void
    @State private var fields: [UUID: Fields] = [:]

    struct Fields: Equatable { var load = "", reps = "", rpe = "" }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    Section("Set \(index + 1)") {
                        field("Weight", unit: "lb", \.load, set.id)
                        field(set.measurements.contains { $0.metric == "duration_s" } ? "Seconds" : "Reps", unit: nil, \.reps, set.id)
                        field("RPE", unit: nil, \.rpe, set.id)
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let number = { (text: String) in Double(text.replacingOccurrences(of: ",", with: ".")) }
                        onSave(fields.mapValues { ClientDay.SetFix(load: number($0.load), reps: number($0.reps), rpe: number($0.rpe)) })
                        dismiss()
                    }
                    .disabled(fields == Self.fields(sets))
                }
            }
        }
        .onAppear { fields = Self.fields(sets) }
    }

    private func field(_ label: String, unit: String?, _ path: WritableKeyPath<Fields, String>, _ id: UUID) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("–", text: Binding(get: { fields[id]?[keyPath: path] ?? "" }, set: { fields[id, default: Fields()][keyPath: path] = $0 }))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
            if let unit { Text(unit).foregroundStyle(Color.inkMuted) }
        }
    }

    static func fields(_ sets: [SyncUnits.LogRow]) -> [UUID: Fields] {
        Dictionary(uniqueKeysWithValues: sets.map { set in
            let value = { (metrics: [String]) in set.measurements.first { metrics.contains($0.metric) }.map { Coach.number($0.value) } ?? "" }
            return (set.id, Fields(load: value(["load_lb", "load_lb_hand"]), reps: value(["reps", "duration_s"]), rpe: value(["rpe"])))
        })
    }
}

/// FIT-340: one message to some or all clients, as Messages' new group text picks people: each gets it in their own
/// conversation, on today.
struct MessageClientsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(Roster.self) private var roster
    @Environment(Account.self) private var account
    @Query private var templates: [Template]
    @State private var picked: Set<String> = []
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Message", text: $text, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    ForEach(roster.clients) { client in
                        Button {
                            if picked.contains(client.id) { picked.remove(client.id) } else { picked.insert(client.id) }
                        } label: {
                            HStack(spacing: 12) {
                                // As the list: accessibility sizes give the name the row's width.
                                if !typeSize.isAccessibilitySize { Avatar(client: client, size: 32) }
                                Text(client.name).foregroundStyle(Color.ink)
                                Spacer()
                                Image(systemName: picked.contains(client.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(client.id) ? AnyShapeStyle(Plate.current.mark) : AnyShapeStyle(Color.inkFaint))
                                    .font(.title3)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    // FIT-367: one Select menu that says what each choice picks; two bare links read as filters.
                    HStack {
                        Text(picked.isEmpty ? "To" : "To · \(picked.count)")
                        Spacer()
                        Menu("Select") {
                            if !roster.needsYou.isEmpty {
                                Button("Who Needs You (\(roster.needsYou.count))") { picked = Set(roster.needsYou.map(\.id)) }
                            }
                            Button("Everyone (\(roster.clients.count))") { picked = Set(roster.clients.map(\.id)) }
                            Button("No One") { picked = [] }.disabled(picked.isEmpty)
                        }
                        .textCase(nil)
                    }
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Message Clients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.count > 1 ? "Send to \(picked.count)" : "Send") { Task { await send() } }
                        .disabled(sending || picked.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func send() async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
        let today = SyncUnits.day(.now)
        sending = true
        var failed: [String] = []
        for id in picked {
            guard var client = roster.clients.first(where: { $0.id == id }) else { continue }
            do {
                client.comments.append(try await Cloud.postComment(words, day: today, client: id))
                roster.update(client, coach: account.user?.uid ?? "", names: names)
            } catch {
                failed.append(client.name)
            }
        }
        sending = false
        if failed.isEmpty { dismiss() } else { problem = "Couldn’t send to \(failed.joined(separator: ", ")). Try again." }
    }
}
