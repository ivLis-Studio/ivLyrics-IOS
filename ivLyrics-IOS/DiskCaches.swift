import Foundation

nonisolated enum LyricsDiskCachePolicy {
    private final class PruneState: @unchecked Sendable {
        var isScheduled = false
        var lastCompletedUptime: TimeInterval?
    }

    private struct CacheEntry {
        var url: URL
        var size: Int64
        var modified: Date
    }

    private enum RemovalOutcome {
        case removed
        case missing
        case changed(CacheEntry)
        case failed
    }

    static let maxAgeMs: Int64 = 365 * 24 * 60 * 60 * 1000
    static let maxTotalBytes: Int64 = 10 * 1024 * 1024 * 1024
    private static let pruneInterval: TimeInterval = 10 * 60
    private static let orphanedTemporaryFileMaxAge: TimeInterval = 60 * 60
    private static let pruneStateQueue = DispatchQueue(label: "ivlyrics.disk-cache.global-prune-state")
    private static let pruneQueue = DispatchQueue(label: "ivlyrics.disk-cache.global-prune", qos: .utility)
    private static let fileAccessLock = NSLock()
    private static let pruneState = PruneState()

    static var rootDirectory: URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cacheRoot.appendingPathComponent("lyrics_cache", isDirectory: true)
    }

    static func prune() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        pruneStateQueue.async {
            guard !pruneState.isScheduled else { return }
            if let lastCompletedUptime = pruneState.lastCompletedUptime,
               requestedAt - lastCompletedUptime < pruneInterval {
                return
            }
            pruneState.isScheduled = true

            pruneQueue.async {
                defer {
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    pruneStateQueue.async {
                        pruneState.lastCompletedUptime = completedAt
                        pruneState.isScheduled = false
                    }
                }
                performPrune()
            }
        }
    }

    private static func performPrune() {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(maxAgeMs) / 1000)
        let temporaryFileCutoff = now.addingTimeInterval(-orphanedTemporaryFileMaxAge)
        var entries: [CacheEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            switch url.pathExtension.lowercased() {
            case "tmp":
                guard url.deletingPathExtension().pathExtension.lowercased() == "json" else { continue }
                if modified < temporaryFileCutoff {
                    _ = removeFileIfUnchanged(at: url, modified: modified, size: size, resourceKeys: resourceKeys)
                }
                continue
            case "json":
                break
            default:
                continue
            }
            if modified < cutoff {
                switch removeFileIfUnchanged(at: url, modified: modified, size: size, resourceKeys: resourceKeys) {
                case .removed, .missing:
                    continue
                case .changed(let currentEntry):
                    entries.append(currentEntry)
                    continue
                case .failed:
                    break
                }
            }
            entries.append(CacheEntry(url: url, size: size, modified: modified))
        }

        var totalBytes = entries.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard totalBytes > maxTotalBytes else { return }
        var candidates = entries
            .sorted(by: { $0.modified < $1.modified })
            .map { (entry: $0, retryAfterChange: true) }
        var candidateIndex = 0
        while totalBytes > maxTotalBytes, candidateIndex < candidates.count {
            let candidate = candidates[candidateIndex]
            candidateIndex += 1
            let entry = candidate.entry
            switch removeFileIfUnchanged(
                at: entry.url,
                modified: entry.modified,
                size: entry.size,
                resourceKeys: resourceKeys
            ) {
            case .removed, .missing:
                totalBytes -= max(0, entry.size)
            case .changed(let currentEntry):
                totalBytes += max(0, currentEntry.size) - max(0, entry.size)
                if candidate.retryAfterChange {
                    candidates.append((entry: currentEntry, retryAfterChange: false))
                }
            case .failed:
                break
            }
        }
    }

    fileprivate static func lockFileAccess() {
        fileAccessLock.lock()
    }

    fileprivate static func unlockFileAccess() {
        fileAccessLock.unlock()
    }

    private static func removeFileIfUnchanged(
        at url: URL,
        modified: Date,
        size: Int64,
        resourceKeys: Set<URLResourceKey>
    ) -> RemovalOutcome {
        lockFileAccess()
        defer { unlockFileAccess() }
        let currentValues: URLResourceValues
        do {
            currentValues = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .failed : .missing
        }
        guard currentValues.isRegularFile == true else { return .missing }
        let currentEntry = CacheEntry(
            url: url,
            size: Int64(currentValues.fileSize ?? 0),
            modified: currentValues.contentModificationDate ?? .distantPast
        )
        guard currentEntry.modified == modified, currentEntry.size == size else {
            return .changed(currentEntry)
        }
        do {
            try FileManager.default.removeItem(at: url)
            return .removed
        } catch {
            return .failed
        }
    }
}

nonisolated final class LyricsDiskCache: @unchecked Sendable {
    private struct Envelope: Codable {
        var version: Int
        var contributorSchemaVersion: Int?
        var cacheKey: String
        var savedAtMs: Int64
        var result: LyricsResult
    }

    private let directory: URL
    private let baseLyricsCache: Bool
    private let maxAgeMs: Int64
    private let queue = DispatchQueue(label: "ivlyrics.disk-cache")

    init(namespace: String, maxEntries: Int, maxAgeMs: Int64? = nil) {
        let safeNamespace = Self.safeNamespace(namespace)
        directory = LyricsDiskCachePolicy.rootDirectory.appendingPathComponent(safeNamespace, isDirectory: true)
        _ = maxEntries
        baseLyricsCache = safeNamespace == "base_lyrics"
        self.maxAgeMs = maxAgeMs.flatMap { $0 > 0 ? $0 : nil } ?? LyricsDiskCachePolicy.maxAgeMs
    }

    func get(_ key: String) -> LyricsResult? {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            let file = fileForKey(key)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let data = try Data(contentsOf: file)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 2 else { return nil }
                if baseLyricsCache, (envelope.contributorSchemaVersion ?? 0) < 13 {
                    return nil
                }
                if envelope.savedAtMs <= 0 || Int64(Date().timeIntervalSince1970 * 1000) - envelope.savedAtMs > maxAgeMs {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                guard !envelope.result.lines.isEmpty else { return nil }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return redactedResultForPersistence(envelope.result)
            } catch {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        }
    }

    func put(_ key: String, result: LyricsResult) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard !key.trimmed.isEmpty, !result.lines.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let envelope = Envelope(
                    version: 2,
                    contributorSchemaVersion: baseLyricsCache ? 13 : nil,
                    cacheKey: key,
                    savedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    result: redactedResultForPersistence(result)
                )
                let data = try JSONEncoder().encode(envelope)
                let file = fileForKey(key)
                let temp = file.appendingPathExtension("tmp")
                try data.write(to: temp, options: .atomic)
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                }
                try FileManager.default.moveItem(at: temp, to: file)
                LyricsDiskCachePolicy.prune()
            } catch {
            }
        }
    }

    func remove(_ key: String) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            try? FileManager.default.removeItem(at: fileForKey(key))
        }
    }

    func removeByKeyPrefix(_ prefix: String) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                    if envelope.cacheKey.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: file)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func clear() {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileForKey(_ key: String) -> URL {
        directory.appendingPathComponent("\(IvLyricsUtilities.sha256(key)).json")
    }

    private func redactedResultForPersistence(_ result: LyricsResult) -> LyricsResult {
        var redacted = result
        redacted.contributors = result.contributors.map { contributor in
            LyricsResult.SyncContributor(
                name: "Anonymous",
                userHash: "",
                profileAvailable: false,
                anonymous: true,
                isPrivate: contributor.isPrivate,
                syncType: contributor.syncType,
                syncPoints: contributor.syncPoints
            )
        }
        return redacted
    }

    private static func safeNamespace(_ namespace: String) -> String {
        let value = namespace.trimmed.lowercased().regexReplacing("[^a-z0-9_-]", with: "_")
        return value.isEmpty ? "default" : value
    }
}

nonisolated final class RawResponseDiskCache: @unchecked Sendable {
    private struct Envelope: Codable {
        var version: Int
        var cacheKey: String
        var savedAtMs: Int64
        var body: String
    }

    private let directory: URL
    private let maxAgeMs: Int64
    private let formatVersion: Int
    private let queue = DispatchQueue(label: "ivlyrics.raw-cache")

    init(namespace: String, maxEntries: Int, maxAgeMs: Int64? = nil, formatVersion: Int = 1) {
        let safeNamespace = namespace.trimmed.lowercased().regexReplacing("[^a-z0-9_-]", with: "_")
        directory = LyricsDiskCachePolicy.rootDirectory.appendingPathComponent(safeNamespace.isEmpty ? "raw" : safeNamespace, isDirectory: true)
        _ = maxEntries
        self.maxAgeMs = maxAgeMs.flatMap { $0 > 0 ? $0 : nil } ?? LyricsDiskCachePolicy.maxAgeMs
        self.formatVersion = max(1, formatVersion)
    }

    func get(_ key: String) -> String {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            let file = fileForKey(key)
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == formatVersion, !envelope.body.isEmpty else { return "" }
                if envelope.savedAtMs <= 0 || Int64(Date().timeIntervalSince1970 * 1000) - envelope.savedAtMs > maxAgeMs {
                    try? FileManager.default.removeItem(at: file)
                    return ""
                }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return envelope.body
            } catch {
                try? FileManager.default.removeItem(at: file)
                return ""
            }
        }
    }

    func put(_ key: String, body: String) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard !key.trimmed.isEmpty, !body.trimmed.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let envelope = Envelope(version: formatVersion, cacheKey: key, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000), body: body)
                try JSONEncoder().encode(envelope).write(to: fileForKey(key), options: .atomic)
                LyricsDiskCachePolicy.prune()
            } catch {
            }
        }
    }

    func remove(_ key: String) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            try? FileManager.default.removeItem(at: fileForKey(key))
        }
    }

    func removeByKeyPrefix(_ prefix: String) {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                do {
                    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                    if envelope.cacheKey.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: file)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func clear() {
        queue.sync {
            LyricsDiskCachePolicy.lockFileAccess()
            defer { LyricsDiskCachePolicy.unlockFileAccess() }
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileForKey(_ key: String) -> URL {
        directory.appendingPathComponent("\(IvLyricsUtilities.sha256(key)).json")
    }

}
