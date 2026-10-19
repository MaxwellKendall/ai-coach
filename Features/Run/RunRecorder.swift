import CoreLocation
import HealthKit
import Observation

/// FIT-185: records a run. GPS fixes go to RunTrack (distance, time, pace, splits) and to the Health workout's route;
/// the Health workout session keeps the run going with the phone locked and collects heart rate when a Watch or
/// AirPods measure it. Without Health (denied, or no Health on this device) the run is still tracked by GPS.
/// The Health workout is saved only when the run is, and thrown away with it.
@Observable @MainActor
final class RunRecorder: NSObject {
    enum Phase { case ready, running, paused, ended }

    private(set) var phase: Phase = .ready
    private(set) var track = RunTrack()
    private(set) var ended: Date?
    /// Beats per minute: the latest, and the run's average.
    private(set) var heartRate: Double?
    private(set) var averageHeartRate: Double?
    private(set) var locationDenied = false

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var route: HKWorkoutRouteBuilder?

    override init() {
        super.init()
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
    }

    /// On opening run mode: ask for location, so the map finds you before Start, then for Health, so its sheet
    /// doesn't cover the run once it's going.
    func prepare() async {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await health.requestAuthorization(toShare: Self.share, read: Self.read)
    }

    private static let share: Set<HKSampleType> = [.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.distanceWalkingRunning),
                                                   HKQuantityType(.activeEnergyBurned)]
    private static let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]

    func start() async {
        guard phase == .ready else { return }
        let now = Date.now
        track.start(at: now)
        phase = .running
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        await startWorkout(at: now)
    }

    func pause() {
        guard phase == .running else { return }
        track.pause(at: .now)
        phase = .paused
        session?.pause()
    }

    func resume() {
        guard phase == .paused else { return }
        track.resume(at: .now)
        phase = .running
        session?.resume()
    }

    /// Stops tracking; the summary then saves or discards.
    func end() {
        guard phase == .running || phase == .paused else { return }
        let now = Date.now
        track.pause(at: now)
        ended = now
        phase = .ended
        stopLocation()
    }

    /// Saves the Health workout and its route. Logging the run here doesn't wait on Health.
    func saveWorkout() async {
        guard let session, let builder, let ended else { return }
        session.end()
        do {
            try await builder.endCollection(at: ended)
            if let workout = try await builder.finishWorkout() {
                _ = try await route?.finishRoute(with: workout, metadata: nil)
            }
        } catch {
            // The run is logged here either way.
        }
        self.session = nil
    }

    func discard() {
        stopLocation()
        session?.end()
        builder?.discardWorkout()
        route?.discard()
        session = nil
    }

    /// Stops the map's location updates when run mode closes without a run.
    func close() {
        if phase == .ready { location.stopUpdatingLocation() }
    }

    private func stopLocation() {
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
    }

    private func startWorkout(at start: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            // Asked when run mode opened; this returns at once unless that was dismissed.
            try await health.requestAuthorization(toShare: Self.share, read: Self.read)
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .running
            configuration.locationType = .outdoor
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            builder.delegate = self
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            self.session = session
            self.builder = builder
            route = HKWorkoutRouteBuilder(healthStore: health, device: nil)
            if phase == .paused { session.pause() }
        } catch {
            session = nil
            builder = nil
        }
    }

    private func received(_ fixes: [RunTrack.Fix], _ locations: [CLLocation]) {
        guard phase == .running else { return }
        fixes.forEach { track.add($0) }
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= RunTrack.worstAccuracy }
        if !good.isEmpty { route?.insertRouteData(good) { _, _ in } }
    }
}

extension RunRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            RunTrack.Fix(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, time: $0.timestamp, accuracy: $0.horizontalAccuracy)
        }
        Task { @MainActor in self.received(fixes, locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.locationDenied = status == .denied || status == .restricted }
    }
}

extension RunRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type), let statistics = workoutBuilder.statistics(for: type) else { return }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let latest = statistics.mostRecentQuantity()?.doubleValue(for: bpm)
        let average = statistics.averageQuantity()?.doubleValue(for: bpm)
        Task { @MainActor in
            self.heartRate = latest
            self.averageHeartRate = average
        }
    }
}
