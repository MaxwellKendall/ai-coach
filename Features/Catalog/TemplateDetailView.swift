import SwiftUI

/// Renders any template generically: short single values as details, everything else as its own list.
struct TemplateDetailView: View {
    let template: Template

    private var details: [TemplateAttribute] { template.attributes.filter(AttributeText.isShort) }
    private var lists: [TemplateAttribute] { template.attributes.filter { !AttributeText.isShort($0) } }

    var body: some View {
        List {
            if !details.isEmpty {
                Section {
                    ForEach(details, id: \.key) { attr in
                        LabeledContent(AttributeText.label(attr.key), value: AttributeText.value(attr.values[0]))
                    }
                }
            }
            ForEach(lists, id: \.key) { attr in
                Section(AttributeText.label(attr.key)) {
                    ForEach(Array(attr.values.enumerated()), id: \.offset) { _, value in
                        if let url = URL(string: value), value.hasPrefix("http") {
                            Link(value, destination: url)
                        } else {
                            Text(AttributeText.value(value))
                        }
                    }
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AttributeText {
    static func label(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Seed tokens like `anterior_deltoids` read as words; prose and URLs are left alone.
    static func value(_ v: String) -> String {
        v.contains(" ") || v.contains("/") ? v : v.replacingOccurrences(of: "_", with: " ")
    }

    static func isShort(_ attr: TemplateAttribute) -> Bool {
        attr.values.count == 1 && attr.values[0].count <= 24
    }
}
