import Foundation
import UIKit

/// Only inputs painted below the moving lyrics belong in this key. Image
/// references are retained so an asynchronous replacement cannot reuse an ID.
struct PictureInPictureStaticFrameKey: Equatable {
    var trackKey: String?
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var title: String
    var artist: String
    var showArtwork: Bool
    var orientation: String
    var backgroundMode: String
    var solidColor: String
    var artwork: UIImage?
    var blurredArtwork: UIImage?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trackKey == rhs.trackKey
            && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.title == rhs.title && lhs.artist == rhs.artist
            && lhs.showArtwork == rhs.showArtwork && lhs.orientation == rhs.orientation
            && lhs.backgroundMode == rhs.backgroundMode && lhs.solidColor == rhs.solidColor
            && lhs.artwork === rhs.artwork && lhs.blurredArtwork === rhs.blurredArtwork
    }
}

/// Retain one BGRA background rather than compositing another image. Copying
/// the original pixels preserves gradient, shadow and artwork rounding exactly.
final class PictureInPictureStaticFrameCache {
    private var key: PictureInPictureStaticFrameKey?
    private var pixels = Data()

    func restore(key next: PictureInPictureStaticFrameKey, into destination: UnsafeMutableRawPointer) -> Bool {
        guard key == next, pixels.count == next.height * next.bytesPerRow, !pixels.isEmpty else { return false }
        pixels.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: pixels.count)
        return true
    }

    func store(key next: PictureInPictureStaticFrameKey, from source: UnsafeRawPointer) {
        pixels = Data(bytes: source, count: next.height * next.bytesPerRow)
        key = next
    }

    func removeAll() {
        key = nil
        pixels = Data()
    }
}
