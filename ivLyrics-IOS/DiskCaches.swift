import Foundation

nonisolated enum LyricsDiskCachePolicy {
    static let maxAgeMs: Int64 = 365 * 24 * 60 * 60 * 1000
    static let maxTotalBytes: Int64 = 10 * 1024 * 1024 * 1024
    private static let pruneQueue = DispatchQueue(label: "ivlyrics.disk-cache.global-prune")

    static var rootDirectory: URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cacheRoot.appendingPathComponent("lyrics_cache", isDirectory: true)
    }

    static func prune() {
        pruneQueue.sync {
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

            let cutoff = Date().addingTimeInterval(-Double(maxAgeMs) / 1000)
            var entries: [(url: URL, size: Int64, modified: Date)] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: resourceKeys), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                entries.append((url, Int64(values.fileSize ?? 0), modified))
            }

            var totalBytes = entries.reduce(Int64(0)) { $0 + max(0, $1.size) }
            guard totalBytes > maxTotalBytes else { return }
            for entry in entries.sorted(by: { $0.modified < $1.modified }) where totalBytes > maxTotalBytes {
                if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                    totalBytes -= max(0, entry.size)
                }
            }
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
            try? FileManager.default.removeItem(at: fileForKey(key))
        }
    }

    func removeByKeyPrefix(_ prefix: String) {
        queue.sync {
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
            try? FileManager.default.removeItem(at: fileForKey(key))
        }
    }

    func removeByKeyPrefix(_ prefix: String) {
        queue.sync {
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
