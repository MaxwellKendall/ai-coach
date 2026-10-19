import Foundation
import Testing
@testable import AICoach

/// FIT-185: run mode's distance, time, pace and splits, and the route's encoding.
struct RunTrackTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_400_000)
    /// About 11.1 m of latitude per 1e-4 degree.
    private func fix(_ step: Int, at seconds: Double, accuracy: Double = 5) -> RunTrack.Fix {
        RunTrack.Fix(latitude: 40 + Double(step) * 1e-4, longitude: -75, time: t0 + seconds, accuracy: accuracy)
    }

    @Test func distanceIsTheSumOfGoodLegs() {
        var run = RunTrack()
        run.start(at: t0)
        for i in 0...10 { run.add(fix(i, at: Double(i) * 4)) }
        #expect(abs(run.meters - 111.2) < 0.1)
        #expect(run.points.count == 11)
        #expect(run.elapsed(at: t0 + 40) == 40)
    }

    @Test func badFixesAddNothing() {
        var run = RunTrack()
        run.start(at: t0)
        run.add(fix(0, at: 0))
        run.add(fix(1, at: 4, accuracy: 60))   // too vague
        run.add(fix(1, at: 4, accuracy: -1))   // invalid
        run.add(RunTrack.Fix(latitude: 40.00001, longitude: -75, time: t0 + 5, accuracy: 5))   // 1 m: standing still
        run.add(fix(50, at: 6))                // 550 m in a second: a jump
        #expect(run.meters == 0)
        run.add(fix(1, at: 8))
        #expect(abs(run.meters - 11.1) < 0.1)
    }

    @Test func pausedTimeAndTheLegAcrossAPauseDontCount() {
        var run = RunTrack()
        run.start(at: t0)
        run.add(fix(0, at: 0))
        run.add(fix(1, at: 5))
        run.pause(at: t0 + 10)
        run.add(fix(2, at: 20))                // ignored while paused
        #expect(run.elapsed(at: t0 + 60) == 10)
        run.resume(at: t0 + 60)
        run.add(fix(9, at: 61))                // the first fix after resuming starts a new stretch
        run.add(fix(10, at: 65))
        #expect(abs(run.meters - 22.2) < 0.1)
        #expect(run.elapsed(at: t0 + 70) == 20)
    }

    @Test func eachMileGetsASplit() {
        var run = RunTrack()
        run.start(at: t0)
        // 11.1 m every 4 s is about 9:39 a mile; 300 legs is just over two miles.
        for i in 0...300 { run.add(fix(i, at: Double(i) * 4)) }
        #expect(run.splits.count == 2)
        #expect(run.splits.allSatisfy { abs($0 - 579) < 5 })
        #expect(run.pace(at: t0 + 1200).map { abs($0 - 579) < 5 } == true)
        #expect(RunTrack.miles(run.meters) == "2.07")
    }

    @Test func routeRoundTripsAsAPolyline() {
        // Google's own example.
        let points = [Polyline.Point(latitude: 38.5, longitude: -120.2), Polyline.Point(latitude: 40.7, longitude: -120.95),
                      Polyline.Point(latitude: 43.252, longitude: -126.453)]
        #expect(Polyline.encode(points) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@") == points)
        #expect(Polyline.decode("not a route!") == nil)
        #expect(Polyline.decode("") == [])
    }
}
