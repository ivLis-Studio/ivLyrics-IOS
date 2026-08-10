import XCTest
@testable import ivLyrics_IOS

final class BoundedLRUCacheTests: XCTestCase {
    func testLeastRecentlyUsedEntryIsEvicted() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "one")
        cache.insert(2, forKey: "two")
        XCTAssertEqual(cache.value(forKey: "one"), 1)

        cache.insert(3, forKey: "three")

        XCTAssertNil(cache.value(forKey: "two"))
        XCTAssertEqual(cache.value(forKey: "one"), 1)
        XCTAssertEqual(cache.value(forKey: "three"), 3)
    }

    func testCachePolicyUsesOneYearAndTenGiB() {
        XCTAssertEqual(LyricsDiskCachePolicy.maxAgeMs, 365 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(LyricsDiskCachePolicy.maxTotalBytes, 10 * 1024 * 1024 * 1024)
    }
}
