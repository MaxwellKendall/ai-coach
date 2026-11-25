import SwiftUI
import Testing
import UIKit
@testable import AICoach

struct BankToTargetTests {
    @Test func flightReturnsBankOnlyWhenMotionAllowedAndOriginKnown() {
        let origin = CGPoint(x: 120, y: 340)

        let active = Bank.flight(to: "avatar", from: origin, reduceMotion: false)
        #expect(active != nil)
        #expect(active?.target == AnyHashable("avatar"))
        #expect(active?.from == origin)

        #expect(Bank.flight(to: "avatar", from: origin, reduceMotion: true) == nil)
        #expect(Bank.flight(to: "avatar", from: nil, reduceMotion: false) == nil)
    }

    @MainActor
    @Test func customChipLandsOnTargetAndReportsArrival() async {
        let origin = CGPoint(x: 100, y: 260)
        let bank = Bank(target: "avatar", from: origin)
        var arrived: [Bank.ID] = []

        let root = VStack {
            Circle()
                .frame(width: 40, height: 40)
                .bankTarget("avatar")
            Spacer()
        }
        .frame(width: 300, height: 400)
        .banking(bank, onArrival: { arrived.append($0) }) {
            Label("Sent", systemImage: "checkmark")
        }

        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(3)
        while arrived.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        window.isHidden = true

        #expect(arrived == [bank.id])
    }

    @MainActor
    @Test func nilBankDoesNotFireArrival() async {
        var arrived: [Bank.ID] = []

        let root = VStack {
            Circle()
                .frame(width: 40, height: 40)
                .bankTarget("avatar")
            Spacer()
        }
        .frame(width: 300, height: 400)
        .banking(nil, onArrival: { arrived.append($0) }) {
            Label("Sent", systemImage: "checkmark")
        }

        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        try? await Task.sleep(for: .milliseconds(300))
        window.isHidden = true

        #expect(arrived.isEmpty)
    }
}
