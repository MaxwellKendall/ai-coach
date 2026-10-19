import Foundation

/// FIT-185: a run's route as one short string, Google's encoded polyline format at 1e-5 degrees (about a metre), so it
/// syncs as a field on the run's log row. https://developers.google.com/maps/documentation/utilities/polylinealgorithm
enum Polyline {
    struct Point: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    static func encode(_ points: [Point]) -> String {
        var out = ""
        var last = (lat: 0, lon: 0)
        for point in points {
            let lat = Int((point.latitude * 1e5).rounded()), lon = Int((point.longitude * 1e5).rounded())
            append(lat - last.lat, to: &out)
            append(lon - last.lon, to: &out)
            last = (lat, lon)
        }
        return out
    }

    /// Nil for a string that isn't a polyline.
    static func decode(_ text: String) -> [Point]? {
        var points: [Point] = []
        var values: [Int] = []
        var result = 0, shift = 0
        for scalar in text.unicodeScalars {
            let byte = Int(scalar.value) - 63
            guard (0..<64).contains(byte) else { return nil }
            result |= (byte & 0x1F) << shift
            shift += 5
            if byte < 0x20 {
                values.append(result & 1 == 1 ? ~(result >> 1) : result >> 1)
                result = 0
                shift = 0
            }
        }
        guard shift == 0, values.count.isMultiple(of: 2) else { return nil }
        var lat = 0, lon = 0
        for index in stride(from: 0, to: values.count, by: 2) {
            lat += values[index]
            lon += values[index + 1]
            points.append(Point(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return points
    }

    private static func append(_ value: Int, to out: inout String) {
        var v = value < 0 ? ~(value << 1) : value << 1
        while v >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1F)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }
}
