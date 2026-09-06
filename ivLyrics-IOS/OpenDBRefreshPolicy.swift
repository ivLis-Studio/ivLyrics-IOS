import Foundation

enum OpenDBRefreshPolicy {
    static let freshMs: Int64 = 6 * 60 * 60 * 1000

    static func isFresh(nowMs: Int64, fetchedAtMs: Int64) -> Bool {
        let age = nowMs - fetchedAtMs
        return fetchedAtMs > 0 && age >= 0 && age < freshMs
    }
}
