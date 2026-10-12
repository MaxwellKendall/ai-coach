import SwiftUI

/// FIT-120: where the program would run, without Pro: what it's waiting for, and the offer.
struct ProOfferBar: View {
    @Environment(Pro.self) private var pro

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pro.trialEligible ? "Your program is ready" : "Your program is paused").font(.headline)
                Text("Your coach plans every week of it with Pro. Logging, progress and groups stay free.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { pro.paywall = true } label: {
                Text(Self.title(trialEligible: pro.trialEligible)).font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.bar, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    nonisolated static func title(trialEligible: Bool) -> String {
        trialEligible ? "Start free for \(Pro.trialDays) days" : "Resume your program"
    }
}
