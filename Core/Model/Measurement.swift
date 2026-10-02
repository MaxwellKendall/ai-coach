import Foundation

/// One typed number. Every domain (training, nutrition, sleep, body) is expressed as measurements,
/// e.g. `reps`, `load_lb`, `rpe`, `kcal`, `protein_g`, `cost_usd`, `sleep_h`, `weight_lb`.
struct Measurement: Codable, Hashable, Sendable {
    var metric: String
    var value: Double
    var unit: String
}
