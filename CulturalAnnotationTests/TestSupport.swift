import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LyricsLine {
    struct Syllable: Equatable {
        var text: String
        var startTimeMs: Int64
        var endTimeMs: Int64

        init(text: String, startTimeMs: Int64, endTimeMs: Int64) {
            self.text = text
            self.startTimeMs = max(0, startTimeMs)
            self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
        }
    }
}
