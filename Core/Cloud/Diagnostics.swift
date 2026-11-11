import Foundation
import MetricKit
import Amplify

/// FIT-384: MetricKit's crash and hang reports, kept on the phone until they reach our server, which logs them for the
/// author (no third-party SDK, CLAUDE.md §3). iOS delivers a report on the launch after the crash or hang; signed out
/// or offline, it waits on disk for the next send.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = Diagnostics()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { Self.keep(payload.jsonRepresentation()) }
        Task { await Self.send() }
    }

    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory) }

    static func keep(_ report: Data, in folder: URL = folder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? report.write(to: folder.appending(path: "\(UUID().uuidString).json"))
    }

    /// Each kept report, sent and then removed; one that fails stays for next time.
    @MainActor static func send(from folder: URL = folder) async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil), !files.isEmpty,
              (try? await Amplify.Auth.fetchAuthSession())?.isSignedIn == true else { return }
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        for file in files where file.pathExtension == "json" {
            guard let report = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let sent = try? await Cloud.run("mutation($p: String!, $a: String!) { reportDiagnostic(payload: $p, app: $a) }",
                                            ["p": report, "a": app], at: "reportDiagnostic", as: Bool?.self)
            if sent != nil { try? FileManager.default.removeItem(at: file) }
        }
    }
}
