import Foundation

/// FIT-185: a run as GPS fixes come in: how far, how long while moving, the pace and each mile's split. Pure, so the
/// rules are tested without a phone. Distance is the sum of the legs between good fixes: a fix worse than 25 m, one
/// under 3 m from the last (standing still), or one that would mean running faster than 12 m/s (a GPS jump) adds
/// nothing. Time paused doesn't count, and the leg across a pause isn't distance.
struct RunTrack: Equatable, Sendable {
    struct Fix: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var time: Date
        /// Horizontal accuracy in metres; negative means invalid, as Core Location reports it.
        var accuracy: Double
    }

    static let mile = Running.mile
    static let worstAccuracy = 25.0
    static let jitter = 3.0
    static let fastest = 12.0

    private(set) var started: Date?
    /// Where the run went, for the map and the saved route.
    private(set) var points: [Polyline.Point] = []
    private(set) var meters = 0.0
    /// Seconds each whole mile took, in order.
    private(set) var splits: [Double] = []
    private var pausedAt: Date?
    private var paused: TimeInterval = 0
    private var last: Fix?
    private var splitStart: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    mutating func start(at time: Date) {
        guard started == nil else { return }
        started = time
    }

    mutating func pause(at time: Date) {
        guard started != nil, pausedAt == nil else { return }
        pausedAt = time
    }

    mutating func resume(at time: Date) {
        guard let pausedAt else { return }
        paused += time.timeIntervalSince(pausedAt)
        self.pausedAt = nil
        last = nil
    }

    /// Moving time.
    func elapsed(at now: Date) -> TimeInterval {
        guard let started else { return 0 }
        return max(0, (pausedAt ?? now).timeIntervalSince(started) - paused)
    }

    /// Seconds per mile so far, once there's enough distance to mean anything.
    func pace(at now: Date) -> Double? {
        meters >= 50 ? elapsed(at: now) / (meters / Self.mile) : nil
    }

    mutating func add(_ fix: Fix) {
        guard started != nil, pausedAt == nil, fix.accuracy >= 0, fix.accuracy <= Self.worstAccuracy else { return }
        guard let last else {
            self.last = fix
            points.append(Polyline.Point(latitude: fix.latitude, longitude: fix.longitude))
            return
        }
        let leg = Self.distance(last, fix)
        guard leg >= Self.jitter else { return }
        let seconds = fix.time.timeIntervalSince(last.time)
        guard seconds > 0, leg / seconds <= Self.fastest else { return }
        meters += leg
        self.last = fix
        points.append(Polyline.Point(latitude: fix.latitude, longitude: fix.longitude))
        while meters >= Double(splits.count + 1) * Self.mile {
            let now = elapsed(at: fix.time)
            splits.append(now - splitStart)
            splitStart = now
        }
    }

    /// Metres between two fixes, on a sphere the Earth's mean radius (haversine).
    static func distance(_ a: Fix, _ b: Fix) -> Double {
        let r = 6_371_008.8, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// "1.25", for a label that says "mi".
    static func miles(_ meters: Double) -> String {
        (meters / mile).formatted(.number.precision(.fractionLength(2)))
    }
}
