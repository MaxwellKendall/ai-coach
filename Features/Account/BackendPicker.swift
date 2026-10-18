#if DEBUG
import SwiftUI

/// Debug only: dev or prod. Each has its own data here, and Amplify is configured once, so switching closes the app,
/// which opens on the other. On the You screen and onboarding's first page, so a fresh prod store isn't a dead end.
struct BackendPicker: View {
    @State private var switching: Backend?

    var body: some View {
        LabeledContent {
            Picker("Backend", selection: Binding(get: { Backend.current }, set: { switching = $0 == Backend.current ? nil : $0 })) {
                ForEach(Backend.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .labelsHidden()
        } label: { Label("Backend (debug)", systemImage: "server.rack") }
        .confirmationDialog("Switch to \(switching?.rawValue.capitalized ?? "")?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                            titleVisibility: .visible, presenting: switching) { backend in
            Button("Switch and Close") {
                UserDefaults.standard.set(backend.rawValue, forKey: "backend")
                exit(0)
            }
        } message: { backend in
            Text("Barbrabell closes. Open it again to use \(backend.rawValue.capitalized)'s account and data; this backend's data stays here for when you switch back.")
        }
    }
}
#endif
