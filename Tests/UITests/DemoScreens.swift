import Foundation

/// FIT-458: the review demo says which screen of appstore/review/screens.json it is showing, and for which role, so
/// scripts/screen-coverage.mjs can tell which screens the video never shows. scripts/demo-video.mjs passes the file as
/// TEST_RUNNER_DEMO_SCREENS (xcodebuild hands the runner DEMO_SCREENS). Without it, marks are dropped.
enum DemoScreens {
    enum Role: String { case solo, client, coach }

    static func shown(_ id: String, as role: Role) {
        guard let path = ProcessInfo.processInfo.environment["DEMO_SCREENS"], !path.isEmpty else { return }
        append("\(role.rawValue) \(id)\n", to: path)
    }

    /// TKL-460: a chapter's part starts here (`begin`, the app up and its frame clean) or ends here (`end`, before a
    /// relaunch or the test's end). scripts/demo-video.mjs starts or stops a recording of the part and acknowledges the
    /// cue in `<cues>.ack`; this waits for that, so nothing before `begin` or after `end` is recorded. xcodebuild hands
    /// the runner TEST_RUNNER_DEMO_CUES as DEMO_CUES; without it (an ordinary test run) cues are dropped.
    static func cue(_ kind: String, _ chapter: Role, timeout: TimeInterval = 30) {
        guard let path = ProcessInfo.processInfo.environment["DEMO_CUES"], !path.isEmpty else { return }
        let id = String(format: "%.6f", Date().timeIntervalSince1970)
        append("\(id) \(kind) \(chapter.rawValue)\n", to: path)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let acked = try? String(contentsOfFile: path + ".ack", encoding: .utf8),
               acked.split(separator: "\n").contains(Substring(id)) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // The recorder never answered: carry on; it reports the part as missing.
    }

    private static func append(_ text: String, to path: String) {
        let line = Data(text.utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}
