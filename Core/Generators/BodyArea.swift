import Foundation

/// Plain-language injury areas ("shoulders", "lower back") as the muscle names exercise cards use.
enum BodyArea {
    static let muscles: [String: Set<String>] = [
        "shoulders": ["anterior_deltoids", "rear_deltoids", "deltoids"],
        "chest": ["pectorals"],
        "upper_back": ["lats", "rhomboids", "mid_trapezius", "traps", "upper_back"],
        "lower_back": ["spinal_erectors"],
        "neck": ["traps"],
        "elbows": ["biceps", "triceps"],
        "wrists": ["forearms"],
        "hips": ["glutes", "adductors"],
        "knees": ["quads"],
        "hamstrings": ["hamstrings"],
        "abs": ["core", "rectus_abdominis", "transverse_abdominis", "obliques"],
    ]

    /// "Lower back" → spinal_erectors. Anything unknown is taken as a muscle name already.
    static func muscles(for areas: some Sequence<String>) -> Set<String> {
        Set(areas.flatMap { area -> Set<String> in
            let key = area.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
            return muscles[key] ?? muscles[key + "s"] ?? [key]
        })
    }

    /// The first body part named in a sentence, as said ("my lower back is tight" → "lower back").
    static func mentioned(in words: [String]) -> String? {
        let text = " " + words.joined(separator: " ") + " "
        let names = muscles.keys.map { $0.replacingOccurrences(of: "_", with: " ") }.sorted { $0.count > $1.count }
        return names.first { name in
            let singular = name.hasSuffix("s") ? String(name.dropLast()) : name
            return text.contains(" \(name) ") || text.contains(" \(singular) ")
        }.map { $0.hasSuffix("s") && $0 != "abs" ? String($0.dropLast()) : $0 }
    }
}
