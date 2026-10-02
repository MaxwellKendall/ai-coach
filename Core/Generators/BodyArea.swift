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
}
