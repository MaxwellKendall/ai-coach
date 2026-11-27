import Foundation
import SwiftUI
import Testing
@testable import AICoach

struct SurfaceMotionTests {
    @Test func shimmerWrapsAfterTheBandClearsTheView() {
        #expect(SurfaceMotion.shimmerPhase(at: 0) == 0)
        #expect(SurfaceMotion.shimmerPhase(at: 0.9) == 0.5)
        #expect(SurfaceMotion.shimmerPhase(at: 1.8) == 0)
    }

    @Test func reducedMotionPulsesGentlyAndFreezesSheen() {
        #expect(abs(SurfaceMotion.pulseOpacity(at: 0) - 0.8) < 0.001)
        #expect(abs(SurfaceMotion.pulseOpacity(at: 1.6) - 1) < 0.001)
        #expect(abs(SurfaceMotion.pulseOpacity(at: 3.2) - 0.8) < 0.001)
        #expect(SurfaceMotion.sheenAngle(.degrees(80), reduceMotion: true) ==
                SurfaceMotion.sheenAngle(.degrees(-10), reduceMotion: true))
        #expect(abs(SurfaceMotion.sheenAngle(.degrees(90), reduceMotion: false) - .pi / 2) < 0.001)
    }
}

/// TKL-935: the waiting states and the phase bars' arrival.
struct WaitingAndGrowthMotionTests {
    @Test func slowShimmerTakesTwiceAsLongToCross() {
        #expect(SurfaceMotion.shimmerPhase(at: 1.8, period: SurfaceMotion.slowShimmer) == 0.5)
        #expect(SurfaceMotion.shimmerPhase(at: SurfaceMotion.slowShimmer, period: SurfaceMotion.slowShimmer) == 0)
        #expect(SurfaceMotion.slowShimmer > 1.8)
    }

    @Test func revealStopsStayOrderedAndInRange() {
        for step in 0...20 {
            let stops = LineReveal.stops(progress: Double(step) / 20)
            #expect(stops.count == 2)
            #expect(stops[0] <= stops[1])
            #expect(stops.allSatisfy { (0...1).contains($0) })
        }
        #expect(LineReveal.stops(progress: 0) == [0, 0])
        #expect(LineReveal.stops(progress: 1) == [1, 1])
    }

    @Test func barsGrowLeftToRightAboutTwentyFiveMillisecondsApartAndTheDotLandsLast() {
        let growth = PhaseBarGrowth()
        #expect(growth.delay(0) == 0)
        #expect(abs(growth.delay(1) - 0.025) < 0.0001)
        #expect(abs(growth.delay(11) - 0.275) < 0.0001)
        #expect(growth.dotDelay(count: 12) > growth.delay(11))
        // A deload settles softer: a longer, less bouncy spring than a training week's.
        #expect(growth.response(deload: true) > growth.response(deload: false))
    }
}
