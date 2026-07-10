import Foundation

nonisolated final class LyricsDiskCache: @unchecked Sendable {
    private struct Envelope: Codable {
        var version: Int
        var contributorSchemaVersion: Int?
        var cacheKey: String
        var savedAtMs: Int64
        var result: LyricsResult
    }

    private let directory: URL
    private let maxEntries: Int
    private let baseLyricsCache: Bool
    private let queue = DispatchQueue(label: "ivlyrics.disk-cache")

    init(namespace: String, maxEntries: Int) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safeNamespace = Self.safeNamespace(namespace)
        directory = root.appendingPathComponent("lyrics_cache/\(safeNamespace)", isDirectory: true)
        self.maxEntries = max(16, maxEntries)
        baseLyricsCache = safeNamespace == "base_lyrics"
    }

    func get(_ key: String) -> LyricsResult? {
        queue.sync {
            let file = fileForKey(key)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let data = try Data(contentsOf: file)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1 else { return nil }
                if baseLyricsCache, (envelope.contributorSchemaVersion ?? 0) < 9 {
                    return nil
                }
                guard !envelope.result.lines.isEmpty else { return nil }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return envelope.result
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
                    version: 1,
                    contributorSchemaVersion: baseLyricsCache ? 9 : nil,
                    cacheKey: key,
                    savedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    result: result
                )
                let data = try JSONEncoder().encode(envelope)
                let file = fileForKey(key)
                let temp = file.appendingPathExtension("tmp")
                try data.write(to: temp, options: .atomic)
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                }
                try FileManager.default.moveItem(at: temp, to: file)
                prune()
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

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxEntries else {
            return
        }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in sorted.prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
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
    private let maxEntries: Int
    private let queue = DispatchQueue(label: "ivlyrics.raw-cache")

    init(namespace: String, maxEntries: Int) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safeNamespace = namespace.trimmed.lowercased().regexReplacing("[^a-z0-9_-]", with: "_")
        directory = root.appendingPathComponent("lyrics_cache/\(safeNamespace.isEmpty ? "raw" : safeNamespace)", isDirectory: true)
        self.maxEntries = max(16, maxEntries)
    }

    func get(_ key: String) -> String {
        queue.sync {
            let file = fileForKey(key)
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1, !envelope.body.isEmpty else { return "" }
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
                let envelope = Envelope(version: 1, cacheKey: key, savedAtMs: Int64(Date().timeIntervalSince1970 * 1000), body: body)
                try JSONEncoder().encode(envelope).write(to: fileForKey(key), options: .atomic)
                prune()
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

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxEntries else {
            return
        }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in sorted.prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
