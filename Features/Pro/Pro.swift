import Foundation
import StoreKit
import UserNotifications

/// FIT-83: the Pro subscription. The one place that answers "is this person Pro?" for the app; the proxy checks the
/// same App Store transaction on its side (FIT-102). Entitlements come from StoreKit 2, so a purchase, a renewal, a
/// refund or a purchase on another device of the same Apple ID shows up here without the app doing anything.
/// FIT-120: Pro runs the program; free keeps logging, progress and groups.
@MainActor @Observable
final class Pro {
    static let annual = "com.maxwellkendall.aicoach.pro.annual"
    static let monthly = "com.maxwellkendall.aicoach.pro.monthly"
    static let products = [annual, monthly]
    /// The annual plan's free trial (author, 2026-10-12): two training weeks, the second one adapted to the first.
    nonisolated static let trialDays = 14

    private(set) var active = false
    /// When the free trial ends, while in one.
    private(set) var trialEnds: Date?
    /// Whether this Apple Account can still have the free trial; someone whose Pro lapsed can't.
    private(set) var trialEligible = true
    /// When the app is showing the paywall; any screen can ask for it.
    var paywall = false
    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    /// Does `action` with Pro; without it, shows the offer instead.
    func gate(_ action: () -> Void) {
        if active { action() } else { paywall = true }
    }

    /// Whether a Pro subscription is in force now: verified, not revoked, not expired.
    func refresh() async {
        var active = false
        var trialEnds: Date?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, Self.products.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expires = transaction.expirationDate, expires < .now { continue }
            active = true
            if transaction.offer?.type == .introductory { trialEnds = transaction.expirationDate }
        }
        #if DEBUG
        // `-pro YES`: Pro without buying, for trying Pro's screens in the simulator.
        if UserDefaults.standard.bool(forKey: "pro") { active = true }
        #endif
        self.active = active
        self.trialEnds = trialEnds
        if let annual = try? await Product.products(for: [Self.annual]).first, let subscription = annual.subscription {
            trialEligible = await subscription.isEligibleForIntroOffer
        }
        await remind(trialEnds)
    }

    // MARK: Trial reminder

    static let reminderID = "pro.trial.reminder"

    /// FIT-120: two days before the trial turns into a paid year, said plainly; nil once that's passed.
    nonisolated static func reminderDate(trialEnds: Date, now: Date = .now) -> Date? {
        let date = trialEnds.addingTimeInterval(-2 * 24 * 3600)
        return date > now ? date : nil
    }

    /// Asked for in context, right after a trial starts (FIT-59: never at launch). Replaced on each refresh, removed
    /// once there's no trial.
    private func remind(_ trialEnds: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        guard let trialEnds, let date = Self.reminderDate(trialEnds: trialEnds),
              (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your free trial ends in 2 days"
        content.body = "Pro renews on \(trialEnds.formatted(.dateTime.month(.wide).day())). To cancel, go to Settings › Apple Account › Subscriptions."
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date),
                                                    repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger))
    }
}
