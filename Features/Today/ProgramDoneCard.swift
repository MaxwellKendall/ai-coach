import SwiftUI

/// FIT-325: a ready-made program past its last week: its recap, and the program to go on to (or another).
struct ProgramDoneCard: View {
    let finished: ReadyProgram
    let next: ReadyProgram
    var recap: () -> Void
    var start: () -> Void
    var pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You finished \(finished.name)").font(.title3.weight(.bold))
            Button(action: recap) {
                HStack(spacing: 4) {
                    Text("See the recap")
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain).padding(.top, 6)
            Button(action: start) {
                Text(next.slug == finished.slug ? "Go Again" : "Start \(next.name)")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary).padding(.top, 18)
            Button("Pick Another", action: pick)
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
