import SwiftUI

/// FIT-122: a gift of Pro, redeemed on the account (bought on the web, barbrabell.com/gift). From You, or a gift's
/// link with the code filled in. The year is kept with the account, so it asks to sign in first.
struct RedeemGiftView: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @State var code = ""
    @State private var signingIn = false
    @State private var working = false
    @State private var failure: String?
    @State private var until: Date?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if let until {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "gift.fill").font(.largeTitle)
                        Text("Pro is yours").font(.title2.bold())
                        Text("Your coach runs your program until \(until.formatted(.dateTime.month(.wide).day().year())). Nothing is charged after it.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    TextField("ABCD-EFGH-JKLM", text: $code)
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(redeem)
                } header: {
                    Text("Gift code")
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else {
                        Text("It's on the gift card, or in its link. A year of Pro starts today.")
                    }
                }
                Section {
                    Button(action: redeem) {
                        HStack {
                            Text(account.user == nil ? "Sign in and redeem" : "Redeem")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(InviteLink.gift(code) == nil || working)
                } footer: {
                    if account.user == nil { Text("Your year of Pro is kept with your account.") }
                }
            }
        }
        .navigationTitle("Redeem a gift")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if until != nil { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { if code.isEmpty { focused = true } }
        .sheet(isPresented: $signingIn, onDismiss: { if account.user != nil { redeem() } }) {
            SignInSheet(reason: "Sign in to redeem your gift.")
        }
    }

    private func redeem() {
        guard let gift = InviteLink.gift(code), !working else { return }
        guard account.user != nil else { signingIn = true; return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let until = try await Cloud.redeemGift(gift)
                await pro.redeemed(until: until)
                withAnimation { self.until = until }
            } catch {
                failure = (error as? Cloud.Failure)?.message ?? "Couldn't redeem it. Check your connection and try again."
            }
        }
    }
}

struct GiftRef: Identifiable {
    let id: String
}
