import Foundation
import CoreFoundation

/// Native, read-only v6 decoder. The cached/network document remains v6; only
/// range/metadata names are adapted at the playback boundary. Timing stays compact.
enum SyncDataV6Codec {
    enum DecodeError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case .invalid(let reason): return "Invalid sync v6: \(reason)" } }
    }
    static let timingKey = "_ivSyncV6Timing"
    private static let maxTime = 86_400_000
    private static let metaKeys: Set<String> = ["speaker", "speaker-color", "speaker-fallback", "kind"]
    private static let units: Set<String> = ["line", "word", "character"]

    struct Timing: RandomAccessCollection {
        struct Mark {
            var end: Int // exclusive codepoint index within this target
            var ms: Int64
            var unit: String
        }
        private let legacy: [Double]?
        private let times: [Int64]
        private let ends: [Int]?
        private let unitTags: [UInt8]?
        private let uniformUnit: UInt8
        private static func tag(_ unit: String) -> UInt8 { unit == "line" ? 0 : unit == "word" ? 1 : 2 }
        private static func name(_ tag: UInt8) -> String { tag == 0 ? "line" : tag == 1 ? "word" : "character" }
        var marks: [Mark] { times.indices.map { Mark(end: ends?[$0] ?? $0 + 1, ms: times[$0], unit: Self.name(unitTags?[$0] ?? uniformUnit)) } }
        let count: Int
        let endSeconds: Double?
        var isV6: Bool { legacy == nil }
        var startIndex: Int { 0 }
        var endIndex: Int { count }
        var storedMarkCount: Int { legacy?.count ?? times.count }
        init(_ values: [Double] = [], endSeconds: Double? = nil) {
            legacy = values; times = []; ends = nil; unitTags = nil; uniformUnit = 2; count = values.count; self.endSeconds = endSeconds
        }
        init(marks: [Mark], count: Int, endMs: Int64? = nil) {
            legacy = nil; self.count = count
            times = marks.map(\.ms)
            ends = marks.count == count && marks.enumerated().allSatisfy { $0.element.end == $0.offset + 1 } ? nil : marks.map(\.end)
            let unit = Self.tag(marks.first?.unit ?? "character")
            uniformUnit = unit
            unitTags = marks.allSatisfy { Self.tag($0.unit) == unit } ? nil : marks.map { Self.tag($0.unit) }
            endSeconds = endMs.map { Double($0) / 1000 }
        }
        func markIndex(at index: Int) -> Int {
            precondition(index >= 0 && index < count)
            if ends == nil { return index }
            var low = 0, high = times.count - 1
            while low < high {
                let middle = (low + high) / 2
                if index < ends![middle] { high = middle } else { low = middle + 1 }
            }
            return low
        }
        subscript(index: Int) -> Double {
            if let legacy { return legacy[index] }
            return Double(times[markIndex(at: index)]) / 1000
        }
        func unit(at index: Int, fallback: String) -> String {
            isV6 ? Self.name(unitTags?[markIndex(at: index)] ?? uniformUnit) : fallback
        }
        /// Different character marks never merge, even when their timestamps match.
        func group(at index: Int) -> Int {
            let mark = markIndex(at: index)
            return unit(at: index, fallback: "character") == "character" ? -(index + 1) : mark
        }
        func sliced(_ bounds: Range<Int>) -> Timing {
            precondition(bounds.lowerBound >= 0 && bounds.upperBound <= count)
            if let legacy { return Timing(Array(legacy[bounds]), endSeconds: bounds.upperBound == count ? endSeconds : nil) }
            var next: [Mark] = []
            var start = 0
            for mark in marks {
                let from = Swift.max(start, bounds.lowerBound), to = Swift.min(mark.end, bounds.upperBound)
                if from < to { next.append(Mark(end: to - bounds.lowerBound, ms: mark.ms, unit: mark.unit)) }
                start = mark.end
            }
            return Timing(marks: next, count: bounds.count, endMs: bounds.upperBound == count ? endSeconds.map { Int64(($0 * 1000).rounded()) } : nil)
        }
        func shifted(by seconds: Double) -> Timing {
            if let legacy { return Timing(legacy.map { Swift.max(0, (($0 + seconds) * 1000).rounded() / 1000) },
                endSeconds: endSeconds.map { Swift.max(0, (($0 + seconds) * 1000).rounded() / 1000) }) }
            let offset = Int64((seconds * 1000).rounded())
            return Timing(marks: marks.map { Mark(end: $0.end, ms: Swift.max(0, $0.ms + offset), unit: $0.unit) }, count: count,
                endMs: endSeconds.map { Swift.max(0, Int64(($0 * 1000).rounded()) + offset) })
        }
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw DecodeError.invalid(reason) }
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw DecodeError.invalid("expected object") }
        return object
    }
    private static func fields(_ value: [String: Any], _ allowed: Set<String>) throws {
        try require(Set(value.keys).isSubset(of: allowed), "unknown fields")
    }
    private static func array(_ value: Any?, max: Int = 2000) throws -> [Any] {
        guard let array = value as? [Any], array.count <= max else { throw DecodeError.invalid("array bound") }
        return array
    }
    private static func integer(_ value: Any?, _ min: Int, _ max: Int, _ label: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw DecodeError.invalid(label) }
        let double = number.doubleValue
        try require(double.isFinite && double.rounded(.towardZero) == double && double >= Double(min) && double <= Double(max), label)
        return Int(double)
    }
    private static func meta(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        let result = try object(value); try fields(result, metaKeys); return result
    }
    private static func ranges(_ value: Any?, offset: Int, length: Int) throws -> [[String: Int]] {
        var previous = 0
        return try array(value).map { raw in
            let pair = try array(raw, max: 2); try require(pair.count == 2, "range pair")
            let from = try integer(pair[0], previous, length - 1, "range start")
            let to = try integer(pair[1], from + 1, length, "range end")
            previous = to
            return ["start": offset + from, "end": offset + to - 1]
        }
    }
    private static func size(_ ranges: [[String: Int]]) -> Int {
        ranges.reduce(0) { $0 + $1["end"]! - $1["start"]! + 1 }
    }

    static func timing(_ raw: Any?, length: Int) throws -> Timing {
        let value = try object(raw)
        try fields(value, ["unit", "startMs", "deltaMs", "lengths", "endMs", "declared", "runs"])
        let undeclared: Bool
        if let declared = value["declared"] {
            try require((declared as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } == true, "declared")
            undeclared = true
        } else { undeclared = false }
        var marks: [Timing.Mark] = []
        if value["unit"] as? String == "mixed" {
            try require(value["startMs"] == nil && value["deltaMs"] == nil && value["lengths"] == nil, "mixed fields")
            let runs = try array(value["runs"], max: length)
            try require(!runs.isEmpty, "empty mixed timing")
            var consumed = 0
            for rawRun in runs {
                let run = try object(rawRun); try fields(run, ["length", "timing"])
                let count = try integer(run["length"], 1, length - consumed, "run length")
                let child = try object(run["timing"])
                try require(child["unit"] as? String != "mixed" && child["endMs"] == nil, "nested mixed/hold")
                let decoded = try timing(child, length: count)
                for mark in decoded.marks { marks.append(.init(end: consumed + mark.end, ms: mark.ms, unit: undeclared ? "character" : mark.unit)) }
                consumed += count
            }
            try require(consumed == length, "mixed coverage")
        } else {
            guard let unit = value["unit"] as? String, units.contains(unit) else { throw DecodeError.invalid("timing unit") }
            try require(value["runs"] == nil, "unexpected runs")
            var time = try integer(value["startMs"], 0, maxTime, "startMs")
            let lengths: [Int]
            if unit == "line" {
                try require(value["deltaMs"] == nil && value["lengths"] == nil, "line marks")
                lengths = [length]
            } else if unit == "word" {
                lengths = try array(value["lengths"], max: length).map { try integer($0, 1, length, "word length") }
                try require(!lengths.isEmpty && lengths.reduce(0, +) == length, "word coverage")
            } else {
                try require(value["lengths"] == nil, "character lengths")
                lengths = Array(repeating: 1, count: length)
            }
            let deltas = unit == "line" ? [] : try array(value["deltaMs"], max: length)
            try require(deltas.count == lengths.count - 1, "delta count")
            var end = 0
            for index in lengths.indices {
                if index > 0 { time += try integer(deltas[index - 1], 0, maxTime, "deltaMs") }
                try require(time <= maxTime, "timing overflow")
                end += lengths[index]; marks.append(.init(end: end, ms: Int64(time), unit: undeclared ? "character" : unit))
            }
        }
        try require(!marks.isEmpty && zip(marks, marks.dropFirst()).allSatisfy { $0.ms <= $1.ms }, "timing order")
        let endMs = try value["endMs"].map { try integer($0, Int(marks.last!.ms) + 1, Swift.min(maxTime, Int(marks.last!.ms) + 60000), "endMs") }
        return Timing(marks: marks, count: length, endMs: endMs.map(Int64.init))
    }

    static func playbackBody(_ data: [String: Any]) throws -> [String: Any] {
        if data["version"] as? String == "6" { throw DecodeError.invalid("document version") }
        guard (data["version"] as? NSNumber)?.doubleValue == 6 else { return data }
        _ = try integer(data["version"], 6, 6, "document version")
        try fields(data, ["version", "timeUnit", "indexUnit", "source", "trackDurationMs", "lines"])
        try require(data["timeUnit"] as? String == "ms" && data["indexUnit"] as? String == "nfc-codepoint", "document encoding")
        if let source = data["source"] { _ = try object(source) }
        if let duration = data["trackDurationMs"] { _ = try integer(duration, 1, maxTime, "trackDurationMs") }
        let rawLines = try array(data["lines"], max: 5000)
        var previous = 0, total = 0
        var result = data
        result["lines"] = try rawLines.map { raw -> [String: Any] in
            let line = try object(raw)
            try fields(line, ["id", "offset", "length", "timing", "derivedTiming", "meta", "styles", "hidden", "continuations", "parallel"])
            let offset = try integer(line["offset"], previous, 10_000_000, "line offset")
            let length = try integer(line["length"], 1, 2000, "line length")
            total += length; try require(total <= 1_000_000, "character budget")
            try require(line["id"] as? String == "l" + String(offset, radix: 36), "line id")
            previous = offset + length
            try require((line["timing"] == nil) != (line["derivedTiming"] == nil), "one parent timing required")
            var next = try meta(line["meta"])
            next["start"] = offset; next["end"] = offset + length - 1
            if let hidden = line["hidden"] { next["hiddenRanges"] = try ranges(hidden, offset: offset, length: length) }
            if let styles = line["styles"] {
                next["styleRanges"] = try array(styles, max: length).map { raw -> [String: Any] in
                    let style = try object(raw); try fields(style, metaKeys.union(["range"]))
                    var value = style; value.removeValue(forKey: "range")
                    for (key, item) in try ranges([style["range"] ?? NSNull()], offset: offset, length: length)[0] { value[key] = item }
                    return value
                }
            }
            if let points = line["continuations"] { next["mergedLineContinuationStarts"] = try array(points).map { offset + (try integer($0, 1, length - 1, "continuation")) } }
            var parts: [[String: Any]] = []
            if let rawParallel = line["parallel"] {
                let parallel = try object(rawParallel); try fields(parallel, ["layout", "parts", "hidden", "splits"])
                try require(parallel["layout"] as? String == "stack", "parallel layout")
                let rawParts = try array(parallel["parts"], max: 16); try require(!rawParts.isEmpty, "parallel parts")
                var ids = Set<String>()
                parts = try rawParts.map { raw in
                    let part = try object(raw); try fields(part, ["id", "role", "ranges", "join", "timing", "meta", "pendingUnit"])
                    guard let id = part["id"] as? String, !id.isEmpty, id.utf16.count <= 32, ids.insert(id).inserted else { throw DecodeError.invalid("part id") }
                    try require(["lead", "background"].contains(part["role"] as? String ?? ""), "part role")
                    let spans = try ranges(part["ranges"], offset: offset, length: length)
                    total += size(spans); try require(total <= 1_000_000 && !spans.isEmpty, "part coverage")
                    let join = try array(part["join"]).map { try integer($0, 0, 2, "join") }
                    try require(join.count == spans.count - 1, "join count")
                    var value = try meta(part["meta"])
                    value["id"] = id; value["role"] = part["role"]; value["ranges"] = spans; value["join"] = join
                    if let pending = part["pendingUnit"] {
                        try require(part["timing"] == nil && units.contains(pending as? String ?? ""), "pending unit")
                        value["granularity"] = pending
                    }
                    if let rawTiming = part["timing"] { try attachTiming(rawTiming, length: size(spans), to: &value) }
                    return value
                }
                var value: [String: Any] = ["layout": "stack", "parts": parts]
                if let hidden = parallel["hidden"] { value["hiddenRanges"] = try ranges(hidden, offset: offset, length: length) }
                if let splits = parallel["splits"] { value["manualSplitPoints"] = try array(splits).map { try integer($0, 1, length - 1, "split") } }
                next["parallel"] = value
            }
            let rawTiming: Any
            if let derived = line["derivedTiming"] {
                rawTiming = try parentTiming(derived, parts: parts, offset: offset, length: length)
            } else { rawTiming = line["timing"] ?? NSNull() }
            try attachTiming(rawTiming, length: length, to: &next)
            return next
        }
        return result
    }

    private static func attachTiming(_ raw: Any, length: Int, to target: inout [String: Any]) throws {
        let value = try object(raw), decoded = try timing(value, length: length)
        target[timingKey] = decoded
        target["granularity"] = value["declared"] == nil && value["unit"] as? String != "mixed" ? value["unit"] : "character"
        if let end = decoded.endSeconds { target["lastCharEnd"] = end }
    }
    private static func parentTiming(_ raw: Any, parts: [[String: Any]], offset: Int, length: Int) throws -> [String: Any] {
        let shape = try object(raw); try fields(shape, ["unit", "lengths", "declared", "endMs"])
        guard let unit = shape["unit"] as? String, units.contains(unit) else { throw DecodeError.invalid("derived unit") }
        var values = Array<Int?>(repeating: nil, count: length)
        for part in parts {
            guard let time = part[timingKey] as? Timing, let spans = part["ranges"] as? [[String: Int]] else { throw DecodeError.invalid("untimed parent part") }
            var cursor = 0
            for span in spans { for absolute in span["start"]!...span["end"]! {
                let local = absolute - offset
                try require(values[local] == nil, "overlapping parent parts")
                values[local] = Int((time[cursor] * 1000).rounded()); cursor += 1
            } }
        }
        try require(!values.contains(where: { $0 == nil }), "parent gap")
        let marks = values.map { $0! }
        try require(zip(marks, marks.dropFirst()).allSatisfy(<=), "parent order")
        var next = shape; next["startMs"] = marks[0]
        if unit == "line" { try require(marks.allSatisfy { $0 == marks[0] }, "derived line") }
        else if unit == "character" { next["deltaMs"] = zip(marks, marks.dropFirst()).map { $1 - $0 } }
        else {
            let lengths = try array(shape["lengths"], max: length).map { try integer($0, 1, length, "word length") }
            try require(!lengths.isEmpty && lengths.reduce(0, +) == length, "derived word coverage")
            var cursor = 0, starts: [Int] = []
            for size in lengths {
                let start = marks[cursor]; try require(marks[cursor..<(cursor + size)].allSatisfy { $0 == start }, "derived word marks")
                starts.append(start); cursor += size
            }
            next["deltaMs"] = zip(starts, starts.dropFirst()).map { $1 - $0 }
        }
        return next
    }
}
