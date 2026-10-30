import SwiftUI
import SwiftData
import StoreKit

/// FIT-83, FIT-120: Pro's offer, on Apple's own subscription store (the plans with their prices, restore, and the terms
/// and privacy links App Review asks for). With a program, the offer is that program: its goals and dates first,
/// then what Pro does with it, then what happens on each day of the trial.
struct PaywallView: View {
    @Environment(Pro.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]

    var body: some View {
        SubscriptionStoreView(productIDs: Pro.products) {
            offer
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

    private var offer: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 14) {
                benefit("figure.strengthtraining.traditional", "Your coach runs the program",
                        "Every week designed from what you lifted the week before, with the weights to use.")
                benefit("bubble.left.and.text.bubble.right", "Talk with your coach, any time",
                        "Short on time, sore, traveling: say so, and the week changes.")
                benefit("text.quote", "Your coach's take on every week",
                        "How it went and what's next, written from your numbers.")
            }
            timeline
            Text("Without Pro you can still log workouts, see your progress and train with your groups.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The program, when there is one: "Squat 245 by Feb 1", and its shape.
    @ViewBuilder private var header: some View {
        let lines = Planner.goalLines(goals)
        if let profile = profiles.first, let weeks = profile.program, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR PROGRAM IS READY").font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                // The first goal is the headline; the rest under it.
                Text(lines[0]).font(.system(size: 30, weight: .bold)).tracking(-0.4)
                if lines.count > 1 {
                    Text(lines.dropFirst().joined(separator: " · ")).font(.headline)
                }
                Text("\(weeks.count) weeks · \(profile.trainingDays.count) days a week · \(profile.sessionMinutes) min")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Barbrabell Pro").font(.system(size: 34, weight: .bold)).tracking(-0.4)
                Text("A coach who plans every week of your program.").font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    /// Blinkist's trial timeline: no surprise on the day it's billed.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.timeline(trialDays: Pro.trialDays, plan: "Pro"), id: \.day) { step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(step.day).font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading)
                    Text(step.what).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(Color.fill, in: .rect(cornerRadius: 16))
    }

    /// What happens on each day of the annual plan's free trial.
    nonisolated static func timeline(trialDays: Int, plan: String = "Pro") -> [(day: String, what: String)] {
        [("Today", "Your program starts, with this week's first session."),
         ("Day \(trialDays - 2)", "A reminder that the trial is ending."),
         ("Day \(trialDays)", "\(plan) begins and the year is billed. Cancel any time before, in Settings.")]
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
