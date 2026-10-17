import Foundation
import StoreKit
import UserNotifications

/// FIT-83: the Pro subscription. The one place that answers "is this person Pro?" for the app; the proxy checks the
/// same App Store transaction on its side (FIT-102). Entitlements come from StoreKit 2, so a purchase, a renewal, a
/// refund or a purchase on another device of the same Apple ID shows up here without the app doing anything.
/// FIT-120: Pro runs the program; free keeps logging, progress and groups. FIT-122: or a year of it, as a gift.
@MainActor @Observable
final class Pro {
    nonisolated static let annual = "com.maxwellkendall.aicoach.pro.yearly"
    nonisolated static let monthly = "com.maxwellkendall.aicoach.pro.monthly"
    nonisolated static let products = [annual, monthly]
    /// The annual plan's free trial (author, 2026-10-12): two training weeks, the second one adapted to the first.
    nonisolated static let trialDays = 14

    /// An App Store subscription (or its trial) is in force.
    private(set) var subscribed = false
    /// FIT-122: Pro from a gift redeemed on the account, until then. Kept on the phone so it holds offline.
    private(set) var giftUntil: Date? = UserDefaults.standard.object(forKey: giftKey) as? Date
    /// FIT-130: the coaches this account has; a coached client has Pro while linked (free during the beta).
    private(set) var coaches: [Cloud.Person] = (UserDefaults.standard.data(forKey: coachesKey))
        .flatMap { try? JSONDecoder().decode([Cloud.Person].self, from: $0) } ?? []
    var active: Bool { subscribed || giftUntil.map { $0 > .now } == true || !coaches.isEmpty }
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
        subscribed = active
        self.trialEnds = trialEnds
        if let annual = try? await Product.products(for: [Self.annual]).first, let subscription = annual.subscription {
            trialEligible = await subscription.isEligibleForIntroOffer
        }
        await remind()
    }

    // MARK: Coaches (FIT-130)

    private static let coachesKey = "pro.coaches"

    /// The account's coaches, from the server; signed out, none. Offline, the last answer stands.
    func refreshCoaches(signedIn: Bool) async {
        guard signedIn else { return setCoaches([]) }
        guard let coaches = try? await Cloud.myCoaches() else { return }
        setCoaches(coaches)
    }

    func setCoaches(_ coaches: [Cloud.Person]) {
        self.coaches = coaches
        UserDefaults.standard.set(try? JSONEncoder().encode(coaches), forKey: Self.coachesKey)
    }

    // MARK: Gifts (FIT-122)

    private static let giftKey = "pro.giftUntil"

    /// The account's gifted Pro, from the server; signed out, there's none. Offline, the last answer stands.
    func refreshGift(signedIn: Bool) async {
        guard signedIn else { return setGift(nil) }
        guard let until = try? await Cloud.giftedPro() else { return }
        setGift(until)
        await remind()
    }

    /// A gift just redeemed: Pro until `until`.
    func redeemed(until: Date) async {
        setGift(until)
        await remind()
    }

    private func setGift(_ until: Date?) {
        giftUntil = until
        UserDefaults.standard.set(until, forKey: Self.giftKey)
    }

    // MARK: Reminders

    static let reminderID = "pro.trial.reminder"

    /// FIT-120: two days before the trial turns into a paid year, said plainly; nil once that's passed.
    nonisolated static func reminderDate(trialEnds: Date, now: Date = .now) -> Date? {
        let date = trialEnds.addingTimeInterval(-2 * 24 * 3600)
        return date > now ? date : nil
    }

    /// FIT-122: two weeks before a gift's year ends, the offer to keep going; nil once that's passed.
    nonisolated static func giftReminderDate(until: Date, now: Date = .now) -> Date? {
        let date = until.addingTimeInterval(-14 * 24 * 3600)
        return date > now ? date : nil
    }

    /// Asked for in context, right after a trial starts or a gift is redeemed (FIT-59: never at launch). Replaced on
    /// each refresh, removed once there's nothing to remind of. A trial's reminder comes first: it's the one that bills.
    private func remind() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        let content = UNMutableNotificationContent()
        let date: Date
        if let trialEnds, let reminder = Self.reminderDate(trialEnds: trialEnds) {
            date = reminder
            content.title = "Your free trial ends in 2 days"
            content.body = "Pro renews on \(trialEnds.formatted(.dateTime.month(.wide).day())). To cancel, go to Settings › Apple Account › Subscriptions."
        } else if !subscribed, let giftUntil, let reminder = Self.giftReminderDate(until: giftUntil) {
            date = reminder
            content.title = "Your gift of Pro ends in 2 weeks"
            content.body = "It runs until \(giftUntil.formatted(.dateTime.month(.wide).day())). Subscribe in the app to keep your coach planning."
        } else {
            return
        }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date),
                                                    repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger))
    }
}
