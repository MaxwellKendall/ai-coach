import SwiftUI

/// FIT-377: the coach's note on a session, in their words, over the session it's about: on Today, at the start of
/// workout mode, and on the coach's own view of the day.
struct SessionNote: View {
    let text: String
    /// Who wrote it: the coach's name on the client's phone; none on the coach's own.
    var by: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "quote.opening").font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.subheadline).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                if let by { Text(by).font(.caption.weight(.semibold)).foregroundStyle(Color.inkMuted) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.fill, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(by.map { "Note from \($0): \(text)" } ?? "Note: \(text)")
    }
}
