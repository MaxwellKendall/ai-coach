import SwiftUI
import StoreKit

/// FIT-83: Pro's paywall, Apple's own subscription store: the plans with their prices, the annual plan's free week,
/// restore, and the terms and privacy links App Review asks for. Only what Pro does today is listed; the coach
/// conversation (FIT-103) joins when it ships.
struct PaywallView: View {
    @Environment(Pro.self) private var pro
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: Pro.products) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rep & Recipe Pro").font(.system(size: 34, weight: .bold)).tracking(-0.4)
                Text("More coaching on top of your program.").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    benefit("arrow.triangle.2.circlepath", "Redesign any week, as often as you like",
                            "Free includes \(FreeLimits.redesignsPerMonth) a month.")
                    benefit("text.quote", "Your coach's take on every week",
                            "A short read of how it went, written from your numbers.")
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .storeButton(.visible, for: .restorePurchases, .policies)
        .storeButton(.visible, for: .cancellation)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success) = result {
                await pro.refresh()
                dismiss()
            }
        }
        .tint(.primary)
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
