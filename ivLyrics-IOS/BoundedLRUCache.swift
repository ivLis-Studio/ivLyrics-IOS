import Foundation

struct BoundedLRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var keys: [Key] { order }

    mutating func value(forKey key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        values[key] = value
        touch(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        order.removeAll { $0 == key }
        return values.removeValue(forKey: key)
    }

    mutating func removeValues(where shouldRemove: (Key, Value) -> Bool) {
        for key in order where values[key].map({ shouldRemove(key, $0) }) == true {
            values.removeValue(forKey: key)
        }
        order.removeAll { values[$0] == nil }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
