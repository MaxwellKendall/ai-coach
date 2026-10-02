import SwiftUI
import SwiftData

struct CatalogScreen: View {
    enum Section: String, CaseIterable { case exercises = "Exercises", recipes = "Recipes", pantry = "Pantry" }

    @State private var section: Section = .exercises
    @State private var search = ""
    @State private var adding: TemplateKind?

    var body: some View {
        Group {
            switch section {
            case .exercises: TemplateList(kind: .exercise, search: search)
            case .recipes: TemplateList(kind: .recipe, search: search)
            case .pantry: PantryList(search: search)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .searchable(text: $search)
        .navigationTitle("Catalog")
        .toolbar {
            if section != .pantry {
                Button("Add", systemImage: "plus") { adding = section == .exercises ? .exercise : .recipe }
            }
        }
        .sheet(item: $adding) { kind in
            NavigationStack { TemplateEditor(kind: kind) }
        }
    }
}

extension TemplateKind: Identifiable {
    var id: String { rawValue }
}

private struct TemplateList: View {
    @Query(sort: \Template.name) private var templates: [Template]
    let kind: TemplateKind
    let search: String

    private var shown: [Template] {
        templates.filter { $0.kind == kind && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }

    var body: some View {
        List(shown) { template in
            NavigationLink {
                TemplateDetailView(template: template)
            } label: {
                VStack(alignment: .leading) {
                    Text(template.name)
                    Text(subtitle(template)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ t: Template) -> String {
        let keys = t.kind == .exercise ? ["movement_pattern", "equipment"] : ["protein", "effort"]
        var parts = keys.flatMap { t.values($0) }.map(AttributeText.value)
        if let servings = t.values("servings").first { parts.append("\(servings) servings") }
        return parts.joined(separator: " · ")
    }
}

private struct PantryList: View {
    @Query(sort: \PantryItem.name) private var items: [PantryItem]
    let search: String

    var body: some View {
        List(items.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { item in
            Toggle(item.name.capitalized, isOn: Binding(
                get: { item.stocked },
                set: { item.stocked = $0; item.updatedAt = .now }))
        }
    }
}
