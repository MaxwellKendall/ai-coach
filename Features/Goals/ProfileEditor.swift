import SwiftUI
import SwiftData

/// Onboarding and later edits of the athlete's settings.
struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var profile: Profile
    @FocusState private var typing: Bool
    let isNew: Bool
    var onSave: () -> Void = {}

    var body: some View {
        Form {
            Section("You") {
                LabeledContent("Age") {
                    TextField("Years", value: blankZero($profile.age), format: .number).keyboardType(.numberPad).focused($typing).multilineTextAlignment(.trailing)
                }
                LabeledContent("Weight (lb)") {
                    TextField("lb", value: blankZero($profile.weightLb), format: .number).keyboardType(.decimalPad).focused($typing).multilineTextAlignment(.trailing)
                }
                LabeledContent("Target weight (lb)") {
                    TextField("Optional", value: $profile.targetWeightLb, format: .number).keyboardType(.decimalPad).focused($typing)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Training days") {
                DayPicker(days: $profile.trainingDays)
                DatePicker("Workout time", selection: time($profile.workoutTime), displayedComponents: .hourAndMinute)
                Picker("Session length", selection: $profile.sessionMinutes) {
                    ForEach([30, 45, 60, 75, 90], id: \.self) { Text("\($0) min") }
                }
            }
            Section("Equipment") {
                ForEach(Profile.allEquipment, id: \.self) { item in
                    Toggle(item.replacingOccurrences(of: "_", with: " ").capitalized, isOn: contains(item, in: $profile.equipment))
                }
            }
            Section {
                TextField("Injured areas, e.g. lower_back", text: list($profile.injuredAreas))
                    .textInputAutocapitalization(.never)
                TextField("Exercises to avoid, e.g. deadlift", text: list($profile.avoidExercises))
                    .textInputAutocapitalization(.never)
                Stepper("Max \(profile.maxWeeklySets) sets a week", value: $profile.maxWeeklySets, in: 20...150, step: 5)
            } header: {
                Text("Constraints")
            } footer: {
                Text("Separate with commas. Exercises loading an injured area are left out of every plan.")
            }
            Section("Style") {
                Picker("Training style", selection: $profile.style) {
                    ForEach(TrainingStyle.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                Toggle("Warm-up sets in the plan", isOn: $profile.warmups)
                Picker("Deload", selection: $profile.deloadEveryWeeks) {
                    Text("Every \(AgeTier.of(age: profile.age).deloadEveryWeeks) weeks (your age tier)").tag(Int?.none)
                    ForEach(4...8, id: \.self) { Text("Every \($0) weeks").tag(Int?.some($0)) }
                }
            }
            Section("Kitchen") {
                ForEach($profile.cookWindows, id: \.self) { $window in
                    HStack {
                        Picker("", selection: $window.day) {
                            ForEach(0..<7, id: \.self) { Text(Self.weekdays[$0]).tag($0) }
                        }
                        .labelsHidden()
                        TextField("Label", text: $window.label)
                        Stepper("\(window.hours.formatted()) h", value: $window.hours, in: 0.5...6, step: 0.5).fixedSize()
                    }
                }
                .onDelete { profile.cookWindows.remove(atOffsets: $0) }
                Button("Add cook window", systemImage: "plus") {
                    profile.cookWindows.append(CookWindow(day: 5, hours: 2, label: "Cook"))
                }
                Picker("Grocery day", selection: $profile.groceryDay) {
                    Text("None").tag(Int?.none)
                    ForEach(0..<7, id: \.self) { Text(Self.weekdays[$0]).tag(Int?.some($0)) }
                }
                LabeledContent("Weekly grocery budget ($)") {
                    TextField("Optional", value: $profile.weeklyBudgetUSD, format: .number).keyboardType(.decimalPad).focused($typing)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "About you" : "Profile")
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            if !isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { save() } }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { save() }.disabled(!profile.isComplete)
                }
            }
        }
    }

    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private func save() {
        profile.updatedAt = .now
        onSave()
        if !isNew { dismiss() }
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
        } set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// New profiles start at 0; show the placeholder instead.
    private func blankZero<Value: Numeric>(_ value: Binding<Value>) -> Binding<Value?> {
        Binding { value.wrappedValue == .zero ? nil : value.wrappedValue } set: { value.wrappedValue = $0 ?? .zero }
    }

    private func contains(_ item: String, in items: Binding<[String]>) -> Binding<Bool> {
        Binding { items.wrappedValue.contains(item) } set: { on in
            items.wrappedValue.removeAll { $0 == item }
            if on { items.wrappedValue.append(item) }
        }
    }

    private func list(_ items: Binding<[String]>) -> Binding<String> {
        Binding { items.wrappedValue.joined(separator: ", ") } set: { items.wrappedValue = Profile.list($0) }
    }
}

/// Seven toggles, Monday first.
private struct DayPicker: View {
    @Binding var days: [Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = days.contains(day)
                Button(String(ProfileEditor.weekdays[day].prefix(1))) {
                    if on { days.removeAll { $0 == day } } else { days = (days + [day]).sorted() }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: .circle)
                .foregroundStyle(on ? Color.white : .primary)
                .buttonStyle(.plain)
                .accessibilityLabel(ProfileEditor.weekdays[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

extension Profile {
    var isComplete: Bool { (13...100).contains(age) && weightLb > 0 && !trainingDays.isEmpty }

    /// "lower_back, Shoulders ," → ["lower_back", "shoulders"].
    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
