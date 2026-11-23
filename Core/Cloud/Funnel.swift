import Foundation

/// TKL-466: the first launch's funnel, each screen to the paywall and the purchase, sent to barbrabell.com/events
/// (infra/lambda/funnel.ts) so first-launch-to-paid can be read per monetization strategy (`npm run funnel -- prod`).
/// Only an event's name and one of the server's enums (a screen id, a plan, a path) leave the phone, with a random
/// install id and the strategy the app is running: never the name, the age or any answer. No sign-in needed.
/// Events wait in a small queue (kept across launches) until the monetization switch has been read this launch, so an
/// install's first batch, which fixes its cohort on the server, carries the strategy it really saw.
@MainActor
enum Funnel {
    enum Name: String, CaseIterable {
        case started = "onboarding_started"
        case screenViewed = "onboarding_screen_viewed"
        case checkStarted = "strength_check_started"
        case checkSkipped = "strength_check_skipped"
        case checkCompleted = "strength_check_completed"
        case resultsViewed = "strength_results_viewed"
        case planStarted = "plan_generation_started"
        case planCompleted = "plan_generation_completed"
        case planFailed = "plan_generation_failed"
        case planReadyViewed = "plan_ready_viewed"
        case paywallViewed = "paywall_viewed"
        case planSelected = "paywall_plan_selected"
        case purchaseStarted = "purchase_started"
        case purchaseCompleted = "purchase_completed"
        case purchaseFailed = "purchase_failed"
        case purchaseRestored = "purchase_restored"
        case paywallDismissed = "paywall_dismissed"
        case completed = "onboarding_completed"
    }

    struct Event: Codable, Equatable, Sendable {
        var name: String
        var detail: String?
    }

    struct Batch: Encodable {
        var install: String
        var strategy: String
        var app: String
        var events: [Event]
    }

    nonisolated static let maxQueued = 100
    private static let queueKey = "funnel.queue"
    private static let installKey = "funnel.install"
    private static var ready = false
    private static var sending = false

    static func track(_ name: Name, _ detail: String? = nil) {
        let event = Event(name: name.rawValue, detail: detail)
        #if DEBUG
        // UI tests and the review demo never reach the server; `funnel.log` is what they'd have sent.
        if DebugRole.uiTesting || DebugRole.demo {
            let line = detail.map { "\(name.rawValue).\($0)" } ?? name.rawValue
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "funnel.log") ?? []) + [line], forKey: "funnel.log")
            return
        }
        #endif
        queued = enqueue(event, to: queued)
        if ready { Task { await flush() } }
    }

    /// At launch, once `Monetization.refresh()` has answered (or failed): from here on events are sent as they happen.
    static func start() async {
        ready = true
        await flush()
    }

    nonisolated static func enqueue(_ event: Event, to queue: [Event]) -> [Event] {
        guard !queue.contains(event) else { return queue }
        let pending = queue + [event]
        guard pending.count > maxQueued else { return pending }
        if let first = pending.first, first.name == Name.screenViewed.rawValue, first.detail == "hero" {
            return [first] + pending.suffix(maxQueued - 1)
        }
        return Array(pending.suffix(maxQueued))
    }

    static func install(in defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: installKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installKey)
        return id
    }

    private static var queued: [Event] {
        get { UserDefaults.standard.data(forKey: queueKey).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: queueKey) }
    }

    /// Sends what's queued; offline, it stays for the next event or launch. A batch the server refuses (400) is dropped.
    private static func flush(web: URL = Backend.current.web) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while case let events = queued, !events.isEmpty {
            let info = Bundle.main.infoDictionary
            let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
            let batch = Batch(install: install(), strategy: Monetization.current.rawValue, app: app, events: events)
            var request = URLRequest(url: web.appending(path: "events"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let body = try? JSONEncoder().encode(batch),
                  let (_, response) = try? await URLSession.shared.upload(for: request, from: body),
                  let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) || status == 400 else { return }
            // Anything tracked while this was in flight stays queued.
            queued = queued.filter { !events.contains($0) }
        }
    }
}
