import Foundation
import StoreKit

/// TKL-466: the first launch's funnel, each screen to the paywall and the purchase, sent to barbrabell.com/events
/// (infra/lambda/funnel.ts) so first-launch-to-paid can be read per monetization strategy (`npm run funnel -- prod`).
/// Only an event's name and one of the server's enums (a screen id, a plan, a path) leave the phone, with a random
/// install id and the strategy the app is running: never the name, the age or any answer. No sign-in needed.
/// Events wait in a small queue (kept across launches) until the monetization switch has been read this launch. The
/// strategy that launch ran with is kept as the install's cohort and sent with every batch after, so a queue sent at a
/// later launch, when the switch may say otherwise, still counts under the strategy its first launch saw.
/// A purchase or trial is sent only with Apple's signed transaction, which the server verifies and classifies; a trial
/// is followed until its first paid renewal reaches the app, and an Ask to Buy purchase until it's approved.
@MainActor
enum Funnel {
    enum Name: String, CaseIterable {
        case started = "onboarding_started"
        case screenViewed = "onboarding_screen_viewed"
        case answerSubmitted = "onboarding_answer_submitted"
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
        case trialStarted = "trial_started"
        case purchaseFailed = "purchase_failed"
        case purchaseRestored = "purchase_restored"
        case paywallDismissed = "paywall_dismissed"
        case completed = "onboarding_completed"
    }

    struct Event: Codable, Equatable, Sendable {
        var name: String
        var detail: String?
        /// Apple's signed transaction, on purchase_completed and trial_started only.
        var jws: String?
    }

    /// The onboarding purchase being followed: its product until StoreKit gives its transaction, then that
    /// subscription (original transaction id), until its paid transaction has been sent.
    struct Watch: Codable, Equatable, Sendable {
        var product: String
        var original: UInt64?
        var trialSent = false
        var paidSent = false
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
    nonisolated private static let cohortKey = "funnel.strategy"
    private static let watchKey = "funnel.watch"
    private static var ready = false
    private static var sending = false

    static func track(_ name: Name, _ detail: String? = nil) {
        record(Event(name: name.rawValue, detail: detail))
    }

    private static func record(_ event: Event) {
        #if DEBUG
        // UI tests and the review demo never reach the server; `funnel.log` is what they'd have sent.
        if DebugRole.uiTesting || DebugRole.demo {
            let line = event.detail.map { "\(event.name).\($0)" } ?? event.name
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "funnel.log") ?? []) + [line], forKey: "funnel.log")
            return
        }
        #endif
        queued = enqueue(event, to: queued)
        if ready { Task { await flush() } }
    }

    /// At launch, once `Monetization.refresh()` has answered (or failed): from here on events are sent as they happen.
    static func start() async {
        _ = cohort(current: Monetization.current)
        ready = true
        await flush()
    }

    /// The strategy the install's first launch ran with, kept from then on.
    nonisolated static func cohort(in defaults: UserDefaults = .standard, current: Monetization) -> String {
        if let saved = defaults.string(forKey: cohortKey) { return saved }
        defaults.set(current.rawValue, forKey: cohortKey)
        return current.rawValue
    }

    // MARK: Questions

    /// A question's answer, as the funnel has it: which question, never the answer; the name only if one was given.
    nonisolated static func answered(_ step: StartFlow.Step, name: String) -> Event? {
        guard step.isQuestion else { return nil }
        if step == .name && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return Event(name: Name.answerSubmitted.rawValue, detail: step.screen)
    }

    static func answer(_ step: StartFlow.Step, name: String) {
        if let event = answered(step, name: name) { record(event) }
    }

    // MARK: Purchases

    /// The onboarding paywall's Buy, before StoreKit's sheet: purchase_started, and the purchase to follow.
    static func purchaseStarting(_ productID: String) {
        track(.purchaseStarted, StoreProducts.funnelName(productID))
        // A subscription already followed stays followed (a second tap, or a plan change after a trial started).
        if watch?.original == nil { watch = Watch(product: productID) }
    }

    /// Cancelled or failed: nothing to follow, unless StoreKit has already given a transaction.
    static func purchaseAbandoned() {
        if watch?.original == nil { watch = nil }
    }

    /// Every verified transaction the app sees (a purchase, Transaction.updates, the entitlements at each refresh):
    /// the followed purchase's trial or payment goes out with Apple's signature on it.
    static func observe(_ result: VerificationResult<StoreKit.Transaction>) {
        guard let current = watch, !current.paidSent, case .verified(let transaction) = result else { return }
        let offer = transaction.offer
        let trial = offer?.type == .introductory && offer?.paymentMode == .freeTrial
        let (next, event) = observe(current, productID: transaction.productID, product: StoreProducts.funnelName(transaction.productID),
                                    originalID: transaction.originalID, trial: trial, jws: result.jwsRepresentation)
        if next != current { watch = next }
        if let event { record(event) }
    }

    nonisolated static func observe(_ watch: Watch, productID: String, product: String?, originalID: UInt64, trial: Bool,
                                    jws: String) -> (Watch, Event?) {
        if let original = watch.original {
            guard original == originalID else { return (watch, nil) }
        } else {
            guard productID == watch.product else { return (watch, nil) }
        }
        guard let product, !watch.paidSent else { return (watch, nil) }
        var next = watch
        next.original = originalID
        if trial {
            guard !watch.trialSent else { return (next, nil) }
            next.trialSent = true
            return (next, Event(name: Name.trialStarted.rawValue, detail: product, jws: jws))
        }
        next.paidSent = true
        return (next, Event(name: Name.purchaseCompleted.rawValue, detail: product, jws: jws))
    }

    /// Whether there's a purchase to follow, so refreshes skip walking the entitlements otherwise.
    static var watching: Bool { watch.map { !$0.paidSent } ?? false }

    private static var watch: Watch? {
        get { UserDefaults.standard.data(forKey: watchKey).flatMap { try? JSONDecoder().decode(Watch.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: watchKey) }
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
            let batch = Batch(install: install(), strategy: cohort(current: Monetization.current), app: app, events: events)
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
