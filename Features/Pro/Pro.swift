import Foundation
import StoreKit

/// FIT-83: the Pro subscription. The one place that answers "is this person Pro?" for the app; the proxy checks the
/// same App Store transaction on its side (FIT-102). Entitlements come from StoreKit 2, so a purchase, a renewal, a
/// refund or a purchase on another device of the same Apple ID shows up here without the app doing anything.
@MainActor @Observable
final class Pro {
    static let annual = "com.maxwellkendall.aicoach.pro.annual"
    static let monthly = "com.maxwellkendall.aicoach.pro.monthly"
    static let products = [annual, monthly]

    private(set) var active = false
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

    /// Whether a Pro subscription is in force now: verified, not revoked, not expired.
    func refresh() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, Self.products.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expires = transaction.expirationDate, expires < .now { continue }
            active = true
        }
        self.active = active
    }
}
