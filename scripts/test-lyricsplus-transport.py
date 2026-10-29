#!/usr/bin/env python3
"""Exercise the shipping LyricsPlus scheduler and parser through real URLSession.

Synthetic URLProtocol responses cover delayed bodies, hedging, stable mirror
preference, cancellation, a shared deadline and unavailable-vs-empty outcomes.
No external service, account or artwork cache is accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
models = (SRC / "Models.swift").read_text()
production_models = models[:models.index("enum AppStatus:")]
checks = r'''
import Foundation

private struct Reply {
    var status = 200
    var body = "{\"type\":\"Line\",\"lyrics\":[{\"time\":1000,\"duration\":2000,\"text\":\"Fixture\"}]}"
    var delay: TimeInterval = 0
    var hangs = false
}
private final class Fixture: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [(String, TimeInterval)] = []
    private static var stopped: [String] = []
    private static var handler: (URLRequest) -> Reply = { _ in Reply() }
    private let stateLock = NSLock()
    private var pending: DispatchWorkItem?
    private var cancelled = false
    static func reset(_ next: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; stopped = []; handler = next
    }
    static var hosts: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    static var times: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.1) }
    static var cancelledHosts: [String] { lock.lock(); defer { lock.unlock() }; return stopped }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append((request.url!.host!, ProcessInfo.processInfo.systemUptime))
        let reply = Self.handler(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !reply.hangs else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            guard !self.cancelled else { return }
            self.client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        stateLock.lock()
        pending = work
        let shouldCancel = cancelled
        stateLock.unlock()
        if shouldCancel { work.cancel() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work) }
    }
    override func stopLoading() {
        stateLock.lock(); cancelled = true; pending?.cancel(); stateLock.unlock()
        Self.lock.lock(); Self.stopped.append(request.url!.host!); Self.lock.unlock()
    }
}
private var assertions = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { fatalError(message) }
}
private func awaitCancellation(of hosts: [String]) async throws {
    // URLSession resumes its cancelled data task before URLProtocol receives stopLoading.
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while !Set(hosts).isSubset(of: Set(Fixture.cancelledHosts)), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
@main private struct Checks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let track = TrackSnapshot(title: "Song", artist: "Artist", album: "Album", durationMs: 120000)
        let bases = ["https://slow.fixture", "https://fast.fixture"]
        Fixture.reset { request in request.url!.host == "slow.fixture" ? Reply(hangs: true) : Reply() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await LyricsPlusProvider.fetch(track: track, isrc: "USAAA2600001", baseURLs: bases, session: session, hedgeDelay: 0.05, totalTimeout: 0.5)
        check(result?.synced?.first?.text == "Fixture", "The usable alternate wins while the first body is stalled")
        check(Fixture.hosts == ["slow.fixture", "fast.fixture"], "At most one request per mirror")
        check(Fixture.times[1] - Fixture.times[0] >= 0.035, "The alternate is staggered rather than raced immediately")
        check(ProcessInfo.processInfo.systemUptime - start < 0.35, "The first mirror cannot block a completed alternate")
        try await awaitCancellation(of: ["slow.fixture"])
        check(Fixture.cancelledHosts.contains("slow.fixture"), "Winner cancels the pending body")
        Fixture.reset { _ in Reply() }
        _ = try await LyricsPlusProvider.fetch(track: track, isrc: "USAAA2600002", baseURLs: bases, session: session, hedgeDelay: 0.2, totalTimeout: 0.5)
        check(Fixture.hosts == ["fast.fixture"], "Subsequent tracks prefer the successful mirror without round robin")

        for invalid in ["empty", "empty-body", "malformed"] {
            let first = "\(invalid).fixture", second = "good-\(invalid).fixture"
            Fixture.reset { request in
                if request.url!.host == first {
                    if invalid == "empty" { return Reply(status: 404, body: "") }
                    return Reply(body: invalid == "empty-body" ? "{\"type\":\"Line\",\"lyrics\":[]}" : "{invalid")
                }
                return Reply()
            }
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://\(first)", "https://\(second)"], session: session, hedgeDelay: 0.3, totalTimeout: 0.5)
            check(outcome?.synced?.isEmpty == false, "\(invalid) response cannot win")
            check(Fixture.hosts == [first, second], "Failure starts the next mirror")
            check(ProcessInfo.processInfo.systemUptime - start < 0.2, "Failure does not wait for the hedge timer")
        }
        Fixture.reset { _ in Reply(status: 404, body: "") }
        let empty = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://empty-a.fixture", "https://empty-b.fixture"], session: session, totalTimeout: 0.5)
        check(empty == nil && Fixture.hosts.count == 2, "Only fully empty mirrors report no lyrics")
        Fixture.reset { request in Reply(status: request.url!.host == "error.fixture" ? 503 : 404, body: "") }
        do {
            _ = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://error.fixture", "https://missing.fixture"], session: session, totalTimeout: 0.5)
            fatalError("Service outage became empty lyrics")
        } catch let error as HTTPStatusError { check(error.statusCode == 503, "An operational failure is retained when other mirror is empty") }

        for body in ["{\"error\":true,\"lyrics\":[]}", "{\"error\":\"Unavailable\",\"lyrics\":[]}", "{}", "{\"lyrics\":null}", "{\"lyrics\":\"invalid\"}"] {
            Fixture.reset { request in request.url!.host == "envelope.fixture" ? Reply(body: body) : Reply(status: 404, body: "") }
            do {
                _ = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://envelope.fixture", "https://empty-envelope.fixture"], session: session, totalTimeout: 0.5)
                fatalError("HTTP 200 error or malformed envelope became empty lyrics")
            } catch let error as URLError { check(error.code == .badServerResponse, "HTTP 200 error and malformed envelopes remain operational failures") }
        }
        Fixture.reset { _ in Reply(body: "{\"error\":false,\"lyrics\":[]}") }
        let emptyBodies = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://empty-body-a.fixture", "https://empty-body-b.fixture"], session: session, totalTimeout: 0.5)
        check(emptyBodies == nil && Fixture.hosts.count == 2, "Explicit empty lyrics arrays remain genuine misses")

        Fixture.reset { _ in Reply(hangs: true) }
        let pending = Task { try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://cancel-a.fixture", "https://cancel-b.fixture"], session: session, hedgeDelay: 0.3, totalTimeout: 1) }
        while Fixture.hosts.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancellation returned lyrics") }
        catch { check(error is CancellationError || (error as? URLError)?.code == .cancelled, "Song change cancels the lookup") }
        check(Fixture.hosts == ["cancel-a.fixture"], "Cancellation does not launch another mirror")
        try await awaitCancellation(of: ["cancel-a.fixture"])
        check(Fixture.cancelledHosts.contains("cancel-a.fixture"), "Cancellation stops the active HTTP request")

        Fixture.reset { _ in Reply(hangs: true) }
        let bothPending = Task { try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://cancel-both-a.fixture", "https://cancel-both-b.fixture"], session: session, hedgeDelay: 0.03, totalTimeout: 1) }
        while Fixture.hosts.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        let cancelStart = ProcessInfo.processInfo.systemUptime
        bothPending.cancel()
        do { _ = try await bothPending.value; fatalError("Cancellation returned lyrics") }
        catch { check(error is CancellationError || (error as? URLError)?.code == .cancelled, "Parent cancellation propagates after hedging") }
        check(ProcessInfo.processInfo.systemUptime - cancelStart < 0.2, "Cancelled group does not wait for the request deadline")
        try await awaitCancellation(of: ["cancel-both-a.fixture", "cancel-both-b.fixture"])
        check(Set(Fixture.cancelledHosts) == Set(["cancel-both-a.fixture", "cancel-both-b.fixture"]), "Parent cancellation stops both bodies")

        Fixture.reset { _ in Reply(hangs: true) }
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await LyricsPlusProvider.fetch(track: track, isrc: "", baseURLs: ["https://timeout-a.fixture", "https://timeout-b.fixture"], session: session, hedgeDelay: 0.03, totalTimeout: 0.15)
            fatalError("Stalled responses ignored deadline")
        } catch let error as URLError { check(error.code == .timedOut, "The shared deadline covers response bodies") }
        check(ProcessInfo.processInfo.systemUptime - timeoutStart < 0.4, "Deadline is shared, not multiplied by mirrors")
        try await awaitCancellation(of: ["timeout-a.fixture", "timeout-b.fixture"])
        check(Set(Fixture.cancelledHosts) == Set(["timeout-a.fixture", "timeout-b.fixture"]), "Deadline cancels both bodies")
        print("LYRICSPLUS_TRANSPORT_PASSED assertions=\(assertions)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-plus-transport-") as directory:
    work = Path(directory)
    (work / "Checks.swift").write_text(production_models + checks)
    sources = [SRC / name for name in ["Utilities.swift", "TinySegmenter.swift", "LyricsPlusProvider.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", *map(str, sources), str(work / "Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True, timeout=15)
