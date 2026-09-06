import Foundation

/// Shares structural queries across views and frames until the next semantic boundary.
/// The small LRU retains the current and 300 ms look-ahead intervals, including seeks.
final class TimelineIntervalCache<Value> {
    private struct Key: Hashable {
        let interval: Int
        let duration: Int64
        let afterTrackEnd: Bool
        let automaticInterludes: Bool
    }
    private let boundaries: [Int64]
    private var values = BoundedLRUCache<Key, Value>(capacity: 4)

    init(boundaries: [Int64]) {
        self.boundaries = Array(Set(boundaries)).sorted()
    }

    func value(position: Int64, duration: Int64, automaticInterludes: Bool, compute: () -> Value) -> Value {
        var lower = 0
        var upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle] <= position { lower = middle + 1 } else { upper = middle }
        }
        let key = Key(interval: lower, duration: duration, afterTrackEnd: position >= duration,
                      automaticInterludes: automaticInterludes)
        if let value = values.value(forKey: key) { return value }
        let value = compute()
        values.insert(value, forKey: key)
        return value
    }
}
