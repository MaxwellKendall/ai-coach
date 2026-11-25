import AVFoundation
import MediaPlayer
import XCTest

/// TKL-801: the live workout in the Dynamic Island and on the Lock Screen, and its buttons working with the app in
/// the background. From a real workout it goes home, opens the island, taps Done set, −10s and Skip there, and checks
/// in the app that each changed the workout. Screenshots of each state go to build/screens/live-*-<appearance>.png
/// (`TEST_RUNNER_APPEARANCE=dark` names the dark run; set the simulator's appearance with
/// `xcrun simctl ui <device> appearance dark` first). Scheme ReviewDemo.
final class LiveActivityUITests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var appearance: String { ProcessInfo.processInfo.environment["APPEARANCE"] ?? "light" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testIslandAndLockScreenButtonsChangeTheWorkout() throws {
        // A run that stopped part way may have left the simulator locked.
        XCUIDevice.shared.press(.home)
        if springboard.staticTexts["Swipe up to open"].waitForExistence(timeout: 2) { unlock() }
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start the lifts' OR label == 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "No Start button")
        start.tap()
        // Past the warm-up to the first set: its Done starts a rest.
        let doneRest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Done · rest'")).firstMatch
        for _ in 0..<12 where !doneRest.waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }
        XCTAssertTrue(doneRest.exists, "Never reached a set with a rest after it")

        // Lifting.
        home()
        save("live-lifting-compact")
        lock()
        save("live-lifting-lockscreen")
        unlock()
        expand()
        save("live-lifting-expanded")

        // Done set from the island logs it and starts its rest, with the app in the background.
        tapInIsland("Done set")
        // Compact first: an island opened by a press stays open after its button, until the app comes and goes.
        app.activate()
        sleep(1)
        home()
        save("live-resting-compact")
        expand()
        save("live-resting-expanded")
        lock()
        save("live-resting-lockscreen")
        unlock()
        app.activate()
        XCTAssertTrue(app.staticTexts["Rest"].waitForExistence(timeout: 10), "Done set didn't start the rest in the app")

        // −10s from the island shortens it; Skip ends it and the next set is on screen.
        let before = restLeft(app)
        home()
        expand()
        tapInIsland("10 seconds less")
        app.activate()
        let after = restLeft(app)
        XCTAssertLessThanOrEqual(after, before - 8, "−10s didn't shorten the rest (\(before) → \(after))")
        home()
        expand()
        tapInIsland("Skip rest")
        app.activate()
        XCTAssertTrue(doneRest.waitForExistence(timeout: 10), "Skip didn't go on to the next set")

        // A rest that runs out: the expanded island transitions from rest controls to "Rest over" + "Done set".
        doneRest.tap()
        // Cut it to about 10 s from the island, counted from the app's clock (the island's ring has no text to read),
        // leaving room for the seconds the taps take, so the button is still there for the last one.
        let left = restLeft(app)
        home()
        expand()
        let less = springboard.buttons["10 seconds less"]
        for _ in 0..<max(0, (left - 15) / 10) where less.exists { less.tap() }
        // Wait for and assert the expanded rest-end transition instead of capturing a stale 0:00 frame.
        let doneSet = springboard.buttons["Done set"].firstMatch
        let restOverText = springboard.staticTexts.matching(NSPredicate(format: "label ==[c] 'Rest over'")).firstMatch
        XCTAssertTrue(doneSet.waitForExistence(timeout: 30), "Expanded island didn't transition to Done set when rest ended")
        XCTAssertTrue(restOverText.waitForExistence(timeout: 5), "Expanded island didn't show Rest over when rest ended")
        XCTAssertFalse(springboard.buttons["Skip rest"].exists, "Expanded island still showed rest controls after rest ended")
        save("live-restover-expanded")
        collapseExpandedIsland()
        _ = springboard.staticTexts["Go"].firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        save("live-restover-compact")
        lock()
        save("live-restover-lockscreen")
        unlock()

        // The finish card: the last set from the list, done.
        app.activate()
        app.buttons["Whole workout"].tap()
        let sets = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Set '"))
        XCTAssertTrue(sets.firstMatch.waitForExistence(timeout: 5), "The list shows no sets")
        sets.element(boundBy: sets.count - 1).tap()
        app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Next'")).firstMatch.tap()
        home()
        save("live-done-compact")
        expand()
        save("live-done-expanded")
        lock()
        save("live-done-lockscreen")
        unlock()
    }

    /// TKL-1023: captures the Dynamic Island's minimal presentation across lifting, resting, rest over, and done
    /// by holding a Now Playing media session from the test runner so iOS splits the Dynamic Island into minimal.
    @MainActor func testMinimalDynamicIslandStates() throws {
        XCUIDevice.shared.press(.home)
        if springboard.staticTexts["Swipe up to open"].waitForExistence(timeout: 2) { unlock() }
        let media = try NowPlayingDriver()
        defer { media.stop() }
        media.start()

        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-workoutMotionFixture", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start the lifts' OR label == 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "No Start button")
        start.tap()
        let doneRest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Done · rest'")).firstMatch
        for _ in 0..<12 where !doneRest.waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }
        XCTAssertTrue(doneRest.exists, "Never reached a set with a rest after it")

        // Lifting (minimal progress ring).
        home()
        media.start()
        sleep(2)
        save("live-lifting-minimal")

        // Resting (10 s fixture rest: minimal draining ring).
        app.activate()
        doneRest.tap()
        sleep(1)
        home()
        media.start()
        sleep(2)
        save("live-resting-minimal")

        // Rest over (wait for the 10 s rest to finish, collapse any expanded alert so the minimal bell shows).
        sleep(12)
        collapseExpandedIsland()
        media.start()
        sleep(2)
        save("live-restover-minimal")

        // Done (last set of the 2-set fixture).
        app.activate()
        let finishDone = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Next'")).firstMatch
        XCTAssertTrue(finishDone.waitForExistence(timeout: 10), "No Done button on final set")
        finishDone.tap()
        sleep(1)
        home()
        media.start()
        sleep(2)
        save("live-done-minimal")
    }

    // MARK: Driving the island

    @MainActor private func home() {
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// Collapses an expanded Dynamic Island back to compact/minimal by tapping the home screen below it.
    @MainActor private func collapseExpandedIsland() {
        if springboard.buttons["Done set"].exists || springboard.buttons["Skip rest"].exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
            sleep(3)
        }
        if springboard.buttons["Done set"].exists || springboard.buttons["Skip rest"].exists {
            XCUIDevice.shared.press(.home)
            sleep(3)
        }
    }

    /// A long press on the Dynamic Island opens it.
    @MainActor private func expand() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        sleep(2)
    }

    @MainActor private func tapInIsland(_ label: String) {
        let button = springboard.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The island has no \(label) button")
        button.tap()
        sleep(3)
    }

    @MainActor private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(1)
        XCUIDevice.shared.press(.home) // wakes the screen, still locked
        sleep(2)
    }

    /// Allows Live Activities the first time the system asks (on the Lock Screen card), then swipes up from the
    /// bottom edge to unlock (the simulator has no passcode).
    @MainActor private func unlock() {
        let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Always Allow' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap(); sleep(1) }
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        bottom.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        sleep(2)
        XCTAssertFalse(springboard.staticTexts["Swipe up to open"].exists, "Still locked")
    }

    /// Seconds left on the rest card in the app.
    @MainActor private func restLeft(_ app: XCUIApplication) -> Int {
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}$'")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "No rest countdown in the app")
        return seconds(clock.label) ?? 0
    }

    /// Seconds left on the island's countdown, if it shows one.
    @MainActor private func restText() -> Int? {
        let clock = springboard.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}$'")).firstMatch
        return clock.exists ? seconds(clock.label) : nil
    }

    private func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    @MainActor private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(appearance).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appending(path: "build/screens")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appending(path: "\(name)-\(appearance).png"))
    }
}

/// Plays quiet looping audio from the UI test runner with Now Playing metadata so SpringBoard shows two concurrent
/// Dynamic Island elements (Now Playing + Barbrabell's workout), rendering Barbrabell in its minimal detached view.
@MainActor private final class NowPlayingDriver {
    private let player: AVAudioPlayer
    private var playTarget: Any?
    private var pauseTarget: Any?

    init() throws {
        player = try AVAudioPlayer(data: Self.quietWav())
        player.numberOfLoops = -1
        player.volume = 0.02
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let commands = MPRemoteCommandCenter.shared()
        if playTarget == nil {
            playTarget = commands.playCommand.addTarget { _ in .success }
            pauseTarget = commands.pauseCommand.addTarget { _ in .success }
            commands.playCommand.isEnabled = true
            commands.pauseCommand.isEnabled = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Training Mix",
            MPMediaItemPropertyArtist: "Barbrabell",
            MPMediaItemPropertyPlaybackDuration: 180.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 15.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if !player.isPlaying {
            player.prepareToPlay()
            player.play()
        }
    }

    func stop() {
        player.stop()
        let commands = MPRemoteCommandCenter.shared()
        if let playTarget { commands.playCommand.removeTarget(playTarget) }
        if let pauseTarget { commands.pauseCommand.removeTarget(pauseTarget) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private static func quietWav() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate) // 1 second
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func append(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func append(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        append("RIFF"); append(36 + dataBytes); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        append("data"); append(dataBytes)
        for i in 0..<sampleCount {
            var sample = Int16(sin(Double(i) * 2 * .pi * 220 / Double(sampleRate)) * 200).littleEndian
            data.append(Data(bytes: &sample, count: 2))
        }
        return data
    }
}
