import Foundation
import Testing
@testable import AICoach

/// FIT-453: a card's button ignores the touch that swiped the card, and only that one.
@MainActor struct SwipeGateTests {
    @Test func aTapWithNoSwipeGoesThrough() {
        #expect(!SwipeGate().swiping())
    }

    @Test func theTouchUpThatEndsASwipeIsIgnoredThenTapsWorkAgain() {
        let gate = SwipeGate()
        let start = Date(timeIntervalSince1970: 1_000)
        gate.moved(at: start)
        #expect(gate.swiping(at: start))
        #expect(gate.swiping(at: start.addingTimeInterval(0.3)))
        #expect(!gate.swiping(at: start.addingTimeInterval(0.5)))
    }
}
