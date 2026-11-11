import Foundation
import Testing
@testable import AICoach

/// FIT-384: a report is kept on disk as it came, one file each, until it's sent.
struct DiagnosticsTests {
    @Test func reportsAreKeptOneFileEachAsTheyCame() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        Diagnostics.keep(Data(#"{"crashDiagnostics":[]}"#.utf8), in: folder)
        Diagnostics.keep(Data(#"{"hangDiagnostics":[]}"#.utf8), in: folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 2 && files.allSatisfy { $0.pathExtension == "json" })
        let texts = try Set(files.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(texts == [#"{"crashDiagnostics":[]}"#, #"{"hangDiagnostics":[]}"#])
    }
}
