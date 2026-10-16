import SwiftUI

/// FIT-134: debug builds keep each spoken attempt, step by step: what was heard and how listening ended, where it
/// was sent, the model's tool calls or answer, and any error. Real failures from the author's phone become eval cases.
/// Release builds record nothing.
enum VoiceLog {
    struct Line: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var said: String
        var step: String
    }

    static func record(_ said: String, _ step: String) {
        #if DEBUG
        var all = lines
        all.append(Line(date: .now, said: said, step: step))
        if let data = try? JSONEncoder().encode(all.suffix(500)) { try? data.write(to: file) }
        #endif
    }

    static var lines: [Line] {
        (try? JSONDecoder().decode([Line].self, from: Data(contentsOf: file))) ?? []
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    /// Every attempt as plain text, newest first, for pasting into an eval.
    static var text: String {
        attempts.map { attempt in
            ([attempt.first.map { "\($0.date.formatted(date: .abbreviated, time: .shortened)) · “\($0.said)”" } ?? ""]
             + attempt.map { "  \($0.step)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Lines grouped by what was said, in a row, newest attempt first.
    static var attempts: [[Line]] {
        var groups: [[Line]] = []
        for line in lines {
            if let last = groups.last?.last, last.said == line.said, line.date.timeIntervalSince(last.date) < 120 {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.reversed()
    }

    private static var file: URL { URL.applicationSupportDirectory.appending(path: "voice-log.json") }
}

#if DEBUG
/// You › Spoken attempts (debug builds only).
struct VoiceLogView: View {
    @State private var attempts = VoiceLog.attempts

    var body: some View {
        List {
            if attempts.isEmpty { Text("Nothing said yet.").foregroundStyle(.secondary) }
            ForEach(attempts, id: \.first?.id) { attempt in
                VStack(alignment: .leading, spacing: 4) {
                    let said = attempt.first?.said ?? ""
                    Text(said.isEmpty ? "Microphone" : "“\(said)”").font(.subheadline.weight(.semibold))
                    ForEach(attempt) { Text($0.step).font(.caption).foregroundStyle(.secondary) }
                    Text(attempt.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
                .textSelection(.enabled)
            }
        }
        .navigationTitle("Spoken attempts")
        .toolbar {
            ShareLink(item: VoiceLog.text)
            Button("Clear", role: .destructive) { VoiceLog.clear(); attempts = [] }
        }
    }
}
#endif
