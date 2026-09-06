import Foundation

/// Provider attempts belong to one lyrics request, including retries for the same track.
struct SupplementProviderProgress {
    private var requestID = UUID()
    private var trackKey = ""
    private(set) var pronunciation = ""
    private(set) var translation = ""

    mutating func begin(trackKey: String) -> UUID {
        requestID = UUID()
        self.trackKey = trackKey
        pronunciation = ""
        translation = ""
        return requestID
    }

    func isCurrent(_ request: UUID, trackKey: String) -> Bool {
        request == requestID && self.trackKey == trackKey
    }

    mutating func update(request: UUID, trackKey: String, task: String, provider: String) {
        guard isCurrent(request, trackKey: trackKey) else { return }
        if task == "translation" { translation = provider }
        else if task == "pronunciation" { pronunciation = provider }
    }

    mutating func setLoading(pronunciation: Bool, translation: Bool) {
        if !pronunciation { self.pronunciation = "" }
        if !translation { self.translation = "" }
    }

    mutating func invalidate() {
        _ = begin(trackKey: "")
    }
}
