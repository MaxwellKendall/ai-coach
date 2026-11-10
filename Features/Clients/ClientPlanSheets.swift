import SwiftUI

/// FIT-335: a run for a client's day: its kind, as the program names them, and its distance in miles.
struct PlanRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let day: String
    let onAdd: (_ kind: String, _ miles: Double) -> Void
    @State private var kind = "easy"
    @State private var miles = 3.0

    static let kinds = [("easy", "Easy"), ("long", "Long"), ("tempo", "Tempo"), ("intervals", "Intervals")]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(ClientScreen.dayTitle(day) == "Today" ? "Run today" : "Run on \(ClientScreen.dayTitle(day))").font(.title2.weight(.bold))
            Picker("Kind", selection: $kind) {
                ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(Coach.number(miles)).font(.display(34, weight: .semibold, relativeTo: .largeTitle)).monospacedDigit()
                    + Text(" mi").font(.title3.weight(.semibold)).foregroundStyle(Color.inkMuted)
                Spacer()
                Stepper("Miles", value: $miles, in: 0.5...30, step: 0.5).labelsHidden()
            }
            Text(Coach.run(kind: kind)).font(.subheadline).foregroundStyle(Color.inkMuted)
            Button("Add Run") {
                onAdd(kind, miles)
                dismiss()
            }
            .buttonStyle(.primary)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.bold))
            DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            Button("\(title) \(ClientScreen.dayTitle(SyncUnits.day(date)))") {
                onPick(date)
                dismiss()
            }
            .buttonStyle(.primary)
            .disabled(SyncUnits.day(date) == from)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
    }
}
