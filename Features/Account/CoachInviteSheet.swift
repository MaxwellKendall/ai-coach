import SwiftUI

/// FIT-130: a coach's invite link, opened signed in. Nothing is shared until the client allows it; then the coach sees
/// their program and training and can change the program, and the client has Pro while coached.
struct CoachInviteSheet: View {
    @Environment(Pro.self) private var pro
    @Environment(\.dismiss) private var dismiss
    let code: String

    @State private var coach: String?
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?
    @State private var accepted: Cloud.Person?
    /// FIT-225: notifications not yet allowed or refused, so the coach's pushes are asked for here, as on first launch.
    @State private var askingPush = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: askingPush ? "bell.badge" : accepted == nil ? "person.2" : "checkmark.circle")
                .font(.system(size: 44))
                .padding(.top, 8)
            if let accepted, askingPush {
                Text("Hear from \(accepted.title)").font(.title2.bold()).multilineTextAlignment(.center)
                Text("A notification when \(accepted.title) changes your week or replies to a session, and a reminder in the evening of a day you haven’t logged. Turn the reminder off any time on You.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Button {
                        Task {
                            await Push.request()
                            withAnimation(.snappy) { askingPush = false }
                        }
                    } label: {
                        Text("Turn On Notifications").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Not Now") { withAnimation(.snappy) { askingPush = false } }.controlSize(.large)
                }
            } else if let accepted {
                Text("\(accepted.title) is your coach").font(.title2.bold()).multilineTextAlignment(.center)
                Text("They'll see your program and how your sessions go, and can change your program. You can stop any time on You.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else if !loaded {
                ProgressView()
                Spacer(minLength: 0)
            } else if let coach {
                Text("Let \(coach) coach you?").font(.title2.bold()).multilineTextAlignment(.center)
                Text("\(coach) will see your program and how your sessions go, and can change your program. You can stop any time on You.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Button { accept() } label: {
                        if working { ProgressView().frame(maxWidth: .infinity) } else { Text("Allow").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(working)
                    Button("Not Now") { dismiss() }.controlSize(.large)
                }
            } else {
                Text("This invite has been used or has expired").font(.title3.bold()).multilineTextAlignment(.center)
                Text("Ask your coach for a new link.").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Close") { dismiss() }.controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .task {
            coach = try? await Cloud.coachInvite(code)
            loaded = true
        }
    }

    private func accept() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let person = try await Cloud.acceptCoach(code)
                pro.setCoaches(pro.coaches.filter { $0.uid != person.uid } + [person])
                askingPush = await Push.undecided()
                accepted = person
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
