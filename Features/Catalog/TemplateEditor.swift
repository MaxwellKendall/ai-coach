import SwiftUI
import SwiftData

/// Add a template by hand, or paste text and let the on-device model fill the form. Nothing is saved
/// until the user taps Save, so every AI parse is reviewed first.
struct TemplateEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Template]

    let kind: TemplateKind
    @State private var name = ""
    @State private var rows: [Row] = []
    @State private var pasted = ""
    @State private var parsing = false
    @State private var parseError: String?

    struct Row: Identifiable {
        let id = UUID()
        var key: String
        var text: String
    }

    var body: some View {
        Form {
            if LanguageModel.isAvailable {
                Section {
                    TextField("Paste or describe a \(kind.rawValue)", text: $pasted, axis: .vertical)
                        .lineLimit(3...8)
                    Button {
                        Task { await parse() }
                    } label: {
                        if parsing { ProgressView() } else { Label("Fill in with AI", systemImage: "sparkles") }
                    }
                    .disabled(pasted.isEmpty || parsing)
                } footer: {
                    if let parseError { Text(parseError).foregroundStyle(.red) }
                }
            }
            Section("Name") {
                TextField("Name", text: $name)
            }
            ForEach($rows) { $row in
                Section {
                    TextField("Field", text: $row.key)
                        .font(.subheadline.weight(.semibold))
                        .textInputAutocapitalization(.never)
                    TextField("One value per line", text: $row.text, axis: .vertical)
                }
            }
            .onDelete { rows.remove(atOffsets: $0) }
            Button("Add field", systemImage: "plus") { rows.append(Row(key: "", text: "")) }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("New \(kind.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func parse() async {
        parsing = true
        defer { parsing = false }
        do {
            let seed = try await TemplateParser.parse(pasted, kind: kind)
            parseError = nil
            name = seed.name
            rows = seed.attributes.map { Row(key: $0.key, text: $0.values.joined(separator: "\n")) }
        } catch {
            parseError = "Couldn't read that. Fill in the fields below instead."
        }
    }

    private func save() {
        let attributes = rows.compactMap { row -> TemplateAttribute? in
            let key = CatalogImporter.snakeCase(row.key)
            let values = row.text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return key.isEmpty || values.isEmpty ? nil : TemplateAttribute(key: key, values: values)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let slug = Slug.unique(trimmed, existing: Set(existing.map(\.slug)))
        context.insert(Template(kind: kind, name: trimmed, slug: slug, attributes: attributes))
        dismiss()
    }
}
