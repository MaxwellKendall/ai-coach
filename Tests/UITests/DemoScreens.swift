import Foundation

/// FIT-458: the review demo says which screen of appstore/review/screens.json it is showing, and for which role, so
/// scripts/screen-coverage.mjs can tell which screens the video never shows. scripts/demo-video.mjs passes the file as
/// TEST_RUNNER_DEMO_SCREENS (xcodebuild hands the runner DEMO_SCREENS). Without it, marks are dropped.
enum DemoScreens {
    enum Role: String { case solo, client, coach }

    static func shown(_ id: String, as role: Role) {
        guard let path = ProcessInfo.processInfo.environment["DEMO_SCREENS"], !path.isEmpty else { return }
        let line = Data("\(role.rawValue) \(id)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}
