import Foundation

extension Measurement {
    /// "5 reps", "155 lb", "58 g protein", "3/5".
    var display: String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        if metric == "servings" { return "×\(number)" }
        if unit == "$" { return "$\(number)" }
        if unit == "g" { return "\(number) g \(metric.replacingOccurrences(of: "_g", with: ""))" }
        if unit.hasPrefix("/") { return number + unit }
        if unit == "ratio" { return "\(value.formatted(.percent.precision(.fractionLength(0)))) \(metric.replacingOccurrences(of: "_rate", with: ""))" }
        return "\(number) \(unit)"
    }
}
