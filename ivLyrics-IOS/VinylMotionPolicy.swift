import Foundation

enum VinylMotionPolicy {
    static func speedPercent(_ value: Int) -> Int { min(300, max(25, value)) }

    static func degrees(base: Double, elapsed: TimeInterval, spinning: Bool, speedPercent: Int) -> Double {
        guard spinning else { return base }
        return (base + max(0, elapsed) * 9 * Double(Self.speedPercent(speedPercent)) / 100)
            .truncatingRemainder(dividingBy: 360)
    }

    /// Removes bracketed version/feature notes only when the opt-in preference is enabled.
    /// Never replaces a title with an empty string or strips unmatched punctuation.
    static func title(_ title: String, simplified: Bool) -> String {
        guard simplified else { return title }
        var result = title
        let pattern = #"\([^()]*\)|\[[^\[\]]*\]|（[^（）]*）|【[^【】]*】"#
        while let range = result.range(of: pattern, options: .regularExpression) {
            result.removeSubrange(range)
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? title : result
    }

    /// Text remains wholly inside the circular album lettering, including on small records.
    static func labelWidth(recordSize: Double) -> Double { max(0, recordSize) * 0.23 }
}
