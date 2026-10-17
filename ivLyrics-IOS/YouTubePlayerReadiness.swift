import Foundation

struct YouTubePlayerSelection: Equatable, Sendable {
    let trackKey: String
    let videoID: String
    let selectionID: UUID
}

struct YouTubePlayerIdentity: Equatable, Sendable {
    let selection: YouTubePlayerSelection
    let sessionID: UUID

    var videoID: String { selection.videoID }

    init(selection: YouTubePlayerSelection) {
        self.selection = selection
        sessionID = UUID()
    }
}

/// A ready acknowledgement belongs to one mounted player document, not a lookup result.
struct YouTubePlayerReadiness: Equatable, Sendable {
    private(set) var identity: YouTubePlayerIdentity?
    private(set) var ready = false
    private var failed = false

    init() {}

    mutating func receive(_ event: String, for identity: YouTubePlayerIdentity) {
        if self.identity != identity {
            self = Self()
            self.identity = identity
        }
        guard !failed else { return }
        switch event {
        case "ready": ready = true
        case "failed", "detached": ready = false; failed = true
        default: break
        }
    }

    func permitsSharing(for identity: YouTubePlayerIdentity) -> Bool {
        self.identity == identity && ready && !failed
    }
}
