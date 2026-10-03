import SwiftUI

/// FIT-41 (prototype board E): a change to the program that was said out loud, shown before anything is saved.
struct AmendSheet: View {
    @Environment(\.dismiss) private var dismiss
    let amend: Amend
    let apply: () -> Void

    struct Amend: Identifiable {
        let id = UUID()
        var said: String
        var travel: [Int]
        var rows: [Row]
    }

    struct Row: Identifiable {
        var head: String
        var tag: String
        var line: String
        var id: String { head }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("“\(amend.said)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            Text("Change the program").font(.title2.weight(.bold)).padding(.top, 10)
            Text("Your goals and target date stay the same.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(amend.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.head).font(.body.weight(.semibold))
                            Spacer()
                            Text(row.tag).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(row.line).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 16)
            Button {
                apply()
                dismiss()
            } label: {
                Text("Apply").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            Button("Keep the program") { dismiss() }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 6)
        }
        .padding(EdgeInsets(top: 28, leading: 22, bottom: 12, trailing: 22))
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }
}
