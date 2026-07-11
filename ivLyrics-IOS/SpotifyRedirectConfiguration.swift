import Foundation

enum SpotifyRedirectConfiguration {
    static let scheme = "musicplayer-auth"
    static let uri = "\(scheme)://callback"
    static let url = URL(string: uri)!
}
