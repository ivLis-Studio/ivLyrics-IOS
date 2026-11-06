import Foundation

private var assertions = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
private func expandLegacy(_ target: [String: Any], length: Int) -> [Double] {
    if let chars = target["chars"] as? [NSNumber] { return chars.map(\.doubleValue) }
    if target["granularity"] as? String == "line", let time = target["timing"] as? NSNumber { return Array(repeating: time.doubleValue, count: length) }
    var values: [Double] = []
    for raw in target["timing"] as? [[NSNumber]] ?? [] { values += Array(repeating: raw[1].doubleValue, count: raw[0].intValue + 1 - values.count) }
    return values
}
private func flatten(_ target: [String: Any], length: Int) -> [String: Any] {
    var result = target
    let values = (target[SyncDataV6Codec.timingKey] as? SyncDataV6Codec.Timing).map(Array.init) ?? expandLegacy(target, length: length)
    result.removeValue(forKey: SyncDataV6Codec.timingKey); result.removeValue(forKey: "timing"); result.removeValue(forKey: "unitLayout")
    result["chars"] = values; result["granularity"] = target["granularity"] ?? "character"
    if var parallel = target["parallel"] as? [String: Any] {
        parallel["parts"] = (parallel["parts"] as! [[String: Any]]).map { part in
            let size = (part["ranges"] as! [[String: Int]]).reduce(0) { $0 + $1["end"]! - $1["start"]! + 1 }
            return flatten(part, length: size)
        }
        result["parallel"] = parallel
    }
    return result
}
private func expandedSyllables(_ syllables: [LyricsLine.Syllable]) -> [[String: Any]] {
    syllables.flatMap { syllable in IvLyricsUtilities.splitChars(syllable.text).map { ["text": $0, "start": syllable.startTimeMs, "style": syllable.styleKey] as [String: Any] } }
}
@main struct SyncV6Checks {
    static func main() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        for vector in fixture["vectors"] as! [[String: Any]] {
            let name = vector["name"] as! String, wire = vector["v6"] as! [String: Any], old = vector["legacy"] as! [String: Any]
            let body = try SyncDataV6Codec.playbackBody(wire)
            let lines = body["lines"] as! [[String: Any]], expected = old["lines"] as! [[String: Any]]
            for (line, before) in zip(lines, expected) {
                let length = (before["end"] as! Int) - (before["start"] as! Int) + 1
                let actual = flatten(line, length: length), reference = flatten(before, length: length)
                check(NSDictionary(dictionary: actual).isEqual(to: reference), "Native v6 decode differs from JS golden: \(name)")
                let timing = line[SyncDataV6Codec.timingKey] as! SyncDataV6Codec.Timing
                if name == "line" { check(timing.storedMarkCount == 1 && timing.count == 9, "Line timing is compact") }
                if name == "word" { check(timing.storedMarkCount == 3 && timing.count == 9, "Word timing is compact") }
                if name == "mixed" { check(timing.unit(at: 0, fallback: "") == "word" && timing.unit(at: 2, fallback: "") == "character", "Mixed units retained") }
                let sliced = timing.sliced(1..<length), shifted = sliced.shifted(by: 0.123)
                check(Array(shifted) == Array(timing.dropFirst()).map { (($0 + 0.123) * 1000).rounded() / 1000 }, "Slice/offset preserves marks: \(name)")
                check(sliced.endSeconds == timing.endSeconds, "Surviving last character retains held end")
            }
            let count = expected.map { ($0["end"] as! Int) + 1 }.max()!
            let text = vector["text"] as? String ?? String(repeating: "x", count: count)
            let base = [LyricsLine(startTimeMs: 0, endTimeMs: 10000, text: text)]
            let native = SyncDataApplier.applyWithDiagnostics(baseLyrics: base, syncBody: wire, track: nil)
            let legacy = SyncDataApplier.applyWithDiagnostics(baseLyrics: base, syncBody: old, track: nil)
            check(!native.lines.isEmpty, "Native renderer did not apply \(name): \(native.diagnostics)")
            check(native.lines.count == legacy.lines.count, "Native/legacy line count: \(name)")
            for (line, before) in zip(native.lines, legacy.lines) {
                check(line.text == before.text, "Visible text unchanged: \(name)")
                check(NSArray(array: expandedSyllables(line.syllables)).isEqual(to: expandedSyllables(before.syllables)), "Codepoint timings/styles unchanged: \(name)")
                check(line.vocalParts.count == before.vocalParts.count, "Vocal count unchanged: \(name)")
                for (part, oldPart) in zip(line.vocalParts, before.vocalParts) {
                    check(part.text == oldPart.text, "Vocal text unchanged: \(name)")
                    check(NSArray(array: expandedSyllables(part.syllables)).isEqual(to: expandedSyllables(oldPart.syllables)), "Vocal timing/styles unchanged: \(name)")
                }
            }
            if name == "parallel-held" {
                check(native.lines[0].syllables.last!.endTimeMs == 4000, "Parent held end preserved")
                check(native.lines[0].vocalParts[0].syllables.last!.endTimeMs == 2200 && native.lines[0].vocalParts[1].syllables.last!.endTimeMs == 3500, "Each vocal keeps its own held end")
            }
            if name == "character" { check(native.lines[0].syllables.last!.endTimeMs == 3000, "Explicit held end preserved") }
            if name == "mixed" { check(native.lines[0].syllables.count == 4 && native.lines[0].syllables[0].sourceGranularity == "word", "Renderer groups only word runs") }
        }
        for vector in fixture["invalid"] as! [[String: Any]] {
            do { _ = try SyncDataV6Codec.playbackBody(vector["v6"] as! [String: Any]); fatalError("Malformed v6 accepted: \(vector["name"]!)") }
            catch { assertions += 1 }
        }
        let old: [String: Any] = ["version": 3, "lines": [["start": 0, "end": 0, "chars": [0.0001]]]]
        let untouched = try SyncDataV6Codec.playbackBody(old)
        check(NSDictionary(dictionary: untouched).isEqual(to: old), "Historical sub-ms payload stays unchanged")
        print("Swift sync v6: \(assertions) checks passed (codec + production playback; no device/network).")
    }
}
