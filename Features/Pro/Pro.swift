import Foundation
import StoreKit
import SwiftUI
import UserNotifications

/// FIT-83: the Pro subscription. The one place that answers "is this person Pro?" for the app; the proxy checks the
/// same App Store transaction on its side (FIT-102). Entitlements come from StoreKit 2, so a purchase, a renewal, a
/// refund or a purchase on another device of the same Apple ID shows up here without the app doing anything.
/// FIT-120: Pro runs the program; free keeps logging, progress and groups. FIT-122: or a year of it, as a gift.
/// FIT-437: two plans, kept apart: Lifter Pro (AI planning for someone training themselves) and Coach Pro (the
/// exhaustive coach MCP). Each is had from the App Store here, or from the server's plan, which both stores write.
@MainActor @Observable
final class Pro {
    nonisolated static let trialDays = StoreProducts.trialDays

    /// The App Store entitlements in force on this Apple Account, verified, from the last refresh.
    private(set) var store: [StoreEntitlement] = []
    /// FIT-122: Pro from a gift redeemed on the account, until then. Kept on the phone so it holds offline.
    private(set) var giftUntil: Date? = UserDefaults.standard.object(forKey: giftKey) as? Date
    /// FIT-130: the coaches this account has; a coached client has Pro while linked (free during the beta).
    private(set) var coaches: [Cloud.Person] = (UserDefaults.standard.data(forKey: coachesKey))
        .flatMap { try? JSONDecoder().decode([Cloud.Person].self, from: $0) } ?? []
    /// The App Store has answered once since launch, so a paywall isn't shown to a subscriber before it knows.
    private(set) var checked = false
    /// FIT-327: lifter Pro on the account, from the server: bought on the web (Stripe), or (FIT-437) in the App Store
    /// on any device. Kept on the phone so it holds offline.
    private(set) var webPro = UserDefaults.standard.bool(forKey: webProKey)
    /// FIT-437: Coach Pro on the account, from the server, either store.
    private(set) var serverCoachPro = UserDefaults.standard.bool(forKey: coachProKey)
    /// FIT-437: which store the server's plan is from ("stripe" or "appstore"), so Manage opens the right one.
    private(set) var sources: [StoreProducts.Plan: String] = [:]

    /// The two plans as of now, from the App Store, the server and gifts.
    var access: Access { Access.of(store: store, serverLifter: webPro, serverCoach: serverCoachPro, giftUntil: giftUntil) }

    /// FIT-422: Pro for someone training themselves, however it was bought: the App Store, a gift or the web. Unlike
    /// `active`, it's never everyone during the pilot and never comes with a coach. It decides who gets AI-designed weeks.
    var lifterPro: Bool {
        #if DEBUG
        // `-pro YES`, or You › Pro (debug).
        if UserDefaults.standard.bool(forKey: "pro") { return true }
        #endif
        return access.lifter
    }
    /// FIT-437: Coach Pro, the exhaustive MCP; coaching itself is free.
    var coachPro: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "coachPro") { return true }
        #endif
        return access.coach
    }
    func has(_ plan: StoreProducts.Plan) -> Bool { plan == .lifter ? lifterPro : coachPro }
    /// The plan is the App Store's on this Apple Account, so Apple's sheet manages it; otherwise it's the web's.
    func inAppStore(_ plan: StoreProducts.Plan) -> Bool {
        store.contains { StoreProducts.plan(of: $0.productID) == plan } || sources[plan] == "appstore"
    }

    /// FIT-422: where this person's weeks come from.
    func weekSource(hasProgram: Bool) -> WeekSource? {
        WeekSource.of(lifterPro: lifterPro, coached: !coaches.isEmpty, hasProgram: hasProgram)
    }
    /// FIT-215: in the pilot, everyone has what the first Pro gated (FIT-120's coach, sharing, redesigns); FIT-437's
    /// plans gate only AI planning (`lifterPro`) and the coach MCP (`coachPro`).
    var active: Bool { Pilot.simple || lifterPro || !coaches.isEmpty }
    /// When Lifter Pro's free trial ends, while in one.
    var trialEnds: Date? { access.trialEnds }
    /// Whether this Apple Account can still have Lifter Pro's free trial; someone whose Pro lapsed can't. Asked by
    /// the paywall, not at launch: asking can bring up the App Store's sign-in, which belongs where buying is.
    var trialEligible = true
    /// When the app is showing the paywall; any screen can ask for it.
    var paywall = false
    /// The signed-in account, whose uid is each purchase's appAccountToken and to whom purchases are registered.
    private(set) var uid: String?
    private var updates: Task<Void, Never>?

    init() {
        guard Pilot.sellsPro else { return }
        // Renewals, refunds, Ask to Buy approvals and purchases on other devices, registered as they come.
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                await self?.register(update)
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    /// Does `action` with Pro; without it, shows the offer instead.
    func gate(_ action: () -> Void) {
        if active { action() } else { paywall = true }
    }

    /// The App Store's entitlements now: verified ones of our products.
    func refresh() async {
        guard Pilot.sellsPro else { return }
        store = await Self.storeEntitlements()
        checked = true
        await remind()
    }

    nonisolated static func storeEntitlements() async -> [StoreEntitlement] {
        var found: [StoreEntitlement] = []
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, StoreProducts.plan(of: transaction.productID) != nil else { continue }
            found.append(StoreEntitlement(transaction))
        }
        return found
    }

    // MARK: Buying (FIT-437)

    enum Bought: Equatable { case bought, pending, cancelled }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Buys `product` for the signed-in account (its uid is the purchase's appAccountToken), then registers it with
    /// the server so the plan is on the account at once: the web and Claude see it too.
    func buy(_ product: Product, with purchase: PurchaseAction) async throws -> Bought {
        #if DEBUG
        // FIT-446: the demo's purchase is local: xcodebuild's UI-test runs leave the app on the real sandbox, which
        // asks for an Apple Account, and the demo has none. It's the same switch as `-pro YES`, and a demo launch starts without it.
        if DebugRole.demo {
            UserDefaults.standard.set(true, forKey: "pro")
            await refresh()
            return .bought
        }
        #endif
        var options: Set<Product.PurchaseOption> = []
        if let token = uid.flatMap(UUID.init(uuidString:)) { options.insert(.appAccountToken(token)) }
        switch try await purchase(product, options: options) {
        case .success(let result):
            guard case .verified(let transaction) = result else {
                throw Failure(message: "The App Store couldn't confirm that purchase. Nothing was added; try again.")
            }
            let problem = await register(result)
            await transaction.finish()
            await refresh()
            if let problem { throw Failure(message: problem) }
            return .bought
        case .pending:
            // Ask to Buy, or a payment to confirm; Transaction.updates brings it when it's approved.
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Restore Purchases: the App Store's purchases for this Apple Account, back on the phone and on the account.
    func restore() async throws {
        try await AppStore.sync()
        await refresh()
        if let problem = await registerCurrent() { throw Failure(message: problem) }
        await refreshServerPlans(signedIn: uid != nil)
    }

    /// Signed in or out. Signed in, the App Store's subscriptions on this phone are registered to the account (a
    /// purchase made signed out, or on another device), then the server's plans are read.
    func signedIn(_ uid: String?) async {
        self.uid = uid
        if uid != nil { _ = await registerCurrent() }
        await refreshServerPlans(signedIn: uid != nil)
    }

    @discardableResult
    private func registerCurrent() async -> String? {
        var problem: String?
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            if let said = await register(entitlement) { problem = said }
        }
        return problem
    }

    /// Registers a verified transaction of ours with the server; what went wrong, if anything. Signed out, it waits
    /// for sign-in. Xcode's local StoreKit testing signs with its own certificate, which the server rightly refuses.
    @discardableResult
    private func register(_ result: VerificationResult<StoreKit.Transaction>) async -> String? {
        guard uid != nil, case .verified(let transaction) = result, let plan = StoreProducts.plan(of: transaction.productID),
              transaction.environment != .xcode else { return nil }
        let renewal = await transaction.subscriptionStatus?.renewalInfo.jwsRepresentation
        do {
            let status = try await Cloud.registerAppStorePurchase(transaction: result.jwsRepresentation, renewalInfo: renewal)
            setServerPlan(plan, Cloud.hasPlan(status.status), source: status.source)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Coaches (FIT-130)

    private static let coachesKey = "pro.coaches"

    /// The account's coaches, from the server; signed out, none. Offline, the last answer stands.
    func refreshCoaches(signedIn: Bool) async {
        #if DEBUG
        // `-coach Sam`: coached by Sam, signed in or not, to look at a client's screens on a simulator (FIT-202).
        if let name = UserDefaults.standard.string(forKey: "coach") {
            return setCoaches([Cloud.Person(uid: "debug-coach", name: name, since: "2026-10-22")])
        }
        #endif
        guard signedIn else { return setCoaches([]) }
        guard let coaches = try? await Cloud.myCoaches() else { return }
        setCoaches(coaches)
    }

    func setCoaches(_ coaches: [Cloud.Person]) {
        self.coaches = coaches
        UserDefaults.standard.set(try? JSONEncoder().encode(coaches), forKey: Self.coachesKey)
    }

    // MARK: The server's plans (FIT-327, FIT-437)

    private static let webProKey = "pro.web"
    private static let coachProKey = "pro.coachServer"

    /// The account's Lifter Pro and Coach Pro as the server has them (either store); signed out, none. Offline, the
    /// last answer stands.
    func refreshServerPlans(signedIn: Bool) async {
        guard signedIn else {
            setWebPro(false)
            setServerPlan(.coach, false, source: nil)
            return
        }
        if let plan = try? await Cloud.proPlan() { setServerPlan(.lifter, Cloud.hasPlan(plan.status), source: plan.source) }
        if let plan = try? await Cloud.coachPlan() { setServerPlan(.coach, Cloud.hasPlan(plan.status), source: plan.source) }
    }

    func setWebPro(_ on: Bool) {
        webPro = on
        UserDefaults.standard.set(on, forKey: Self.webProKey)
    }

    func setServerPlan(_ plan: StoreProducts.Plan, _ on: Bool, source: String?) {
        sources[plan] = on ? source : nil
        switch plan {
        case .lifter: setWebPro(on)
        case .coach:
            serverCoachPro = on
            UserDefaults.standard.set(on, forKey: Self.coachProKey)
        }
    }

    // MARK: Gifts (FIT-122)

    private static let giftKey = "pro.giftUntil"

    /// The account's gifted Pro, from the server; signed out, there's none. Offline, the last answer stands.
    func refreshGift(signedIn: Bool) async {
        guard signedIn, Pilot.gifts else { return setGift(nil) }
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
            content.body = "Lifter Pro renews on \(trialEnds.formatted(.dateTime.month(.wide).day())). To cancel, go to Settings › Apple Account › Subscriptions."
        } else if !access.lifterInStore, let giftUntil, let reminder = Self.giftReminderDate(until: giftUntil) {
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

/// FIT-437: one verified App Store entitlement, as deciding the plans needs it.
struct StoreEntitlement: Equatable, Sendable {
    var productID: String
    var expires: Date?
    var revoked: Bool = false
    /// In the introductory offer: Lifter Pro's free trial.
    var trial: Bool = false
}

extension StoreEntitlement {
    init(_ transaction: StoreKit.Transaction) {
        self.init(productID: transaction.productID, expires: transaction.expirationDate, revoked: transaction.revocationDate != nil,
                  trial: transaction.offer?.type == .introductory)
    }
}

/// FIT-437: who has which plan. Lifter Pro and Coach Pro are separate: one never brings the other. Each is had from an
/// App Store subscription of its group that's neither revoked nor expired, or the server's plan (Stripe on the web, or
/// the App Store on another device, in grace or billing retry as the server counts it). A gift is Lifter Pro.
struct Access: Equatable, Sendable {
    var lifter = false
    var coach = false
    /// Lifter Pro from an App Store subscription on this Apple Account.
    var lifterInStore = false
    var trialEnds: Date?

    static func of(store: [StoreEntitlement], serverLifter: Bool, serverCoach: Bool, giftUntil: Date?, now: Date = .now) -> Access {
        var access = Access()
        for entitlement in store where !entitlement.revoked && entitlement.expires.map({ $0 > now }) != false {
            switch StoreProducts.plan(of: entitlement.productID) {
            case .lifter?:
                access.lifterInStore = true
                if entitlement.trial { access.trialEnds = entitlement.expires }
            case .coach?: access.coach = true
            case nil: break
            }
        }
        access.lifter = access.lifterInStore || serverLifter || giftUntil.map { $0 > now } == true
        access.coach = access.coach || serverCoach
        return access
    }
}
