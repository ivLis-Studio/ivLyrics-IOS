#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs only the exact statically inspected Spotify 9.1.60 ABI.
/// A successful result is not a claim of real-device compatibility.
FOUNDATION_EXPORT BOOL IVLyricsSpotifyInstallHostHooks(void);
FOUNDATION_EXPORT BOOL IVLyricsSpotifyHostIsAvailable(void);

NS_ASSUME_NONNULL_END
