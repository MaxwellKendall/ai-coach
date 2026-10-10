import AppIntents
import SwiftData

/// FIT-65: the coach from anywhere. One intent opens it listening (the Action button, Siri, Spotlight); another logs a
/// weight without opening the app.
struct TalkToCoachIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Coach"
    static let description = IntentDescription("Opens Rep & Recipe listening, ready for what you say.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        Navigator.shared.coach = true
        return .result()
    }
}

struct LogWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Weight"
    static let description = IntentDescription("Logs your body weight in Rep & Recipe.")

    @Parameter(title: "Weight", description: "In pounds", inclusiveRange: (50, 700))
    var pounds: Double

    /// The number is the user's, said or typed to Siri; nothing is parsed by a model, so there's no check sheet.
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppSchema.shared.mainContext
        context.insert(LogEntry(kind: .bodyweight, measurements: [Measurement(metric: "weight_lb", value: pounds, unit: "lb")]))
        try context.save()
        return .result(dialog: "Logged \(Coach.number(pounds)) lb.")
    }
}

struct CoachShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToCoachIntent(), phrases: ["Talk to \(.applicationName)", "Open the coach in \(.applicationName)"],
                    shortTitle: "Talk to Coach", systemImageName: "sparkles")
        AppShortcut(intent: LogWeightIntent(), phrases: ["Log my weight in \(.applicationName)", "Log weight in \(.applicationName)"],
                    shortTitle: "Log Weight", systemImageName: "scalemass")
    }
}
