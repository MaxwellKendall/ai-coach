import CoreGraphics
import Testing
@testable import AICoach

/// TKL-1086: at rest the deck draws only the selected card, so a taller next card never shows below a shorter one.
/// The card underneath is drawn only while the top card is moving: dragged, thrown, or settling back.
struct SwipeDeckTests {
    @Test func idleDeckRendersOnlyTheSelectedCard() {
        #expect(SwipeDeckLayout.positions(index: 1, count: 4, under: 2, moving: false) == [1])
        #expect(SwipeDeckLayout.positions(index: 0, count: 1, under: 1, moving: false) == [0])
    }

    @Test func movingDeckRendersTheCardUnderneathToo() {
        #expect(SwipeDeckLayout.positions(index: 1, count: 4, under: 2, moving: true) == [2, 1])
        #expect(SwipeDeckLayout.positions(index: 1, count: 4, under: 0, moving: true) == [0, 1])
    }

    @Test func cardsPastEitherEndAreNeverRendered() {
        #expect(SwipeDeckLayout.positions(index: 3, count: 4, under: 4, moving: true) == [3])
        #expect(SwipeDeckLayout.positions(index: 0, count: 4, under: -1, moving: true) == [0])
    }

    @Test func moving() {
        #expect(!SwipeDeckLayout.moving(drag: .zero, throwing: false, settling: false))
        #expect(SwipeDeckLayout.moving(drag: CGSize(width: -3, height: 0), throwing: false, settling: false))
        #expect(SwipeDeckLayout.moving(drag: CGSize(width: 0, height: 5), throwing: false, settling: false))
        // A throw's last frame and a settle back both end at .zero, still animating: keep the card underneath.
        #expect(SwipeDeckLayout.moving(drag: .zero, throwing: true, settling: false))
        #expect(SwipeDeckLayout.moving(drag: .zero, throwing: false, settling: true))
    }
}
