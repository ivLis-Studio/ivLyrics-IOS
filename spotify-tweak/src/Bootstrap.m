#import <Foundation/Foundation.h>

extern void IVLyricsSpotifyBootstrap(void);

// Loading a development build must not change an uninspected host application.
// A version-specific Spotify adapter will call the bridge after validation.
__attribute__((constructor)) static void IVLyricsSpotifyLoad(void) {
    @autoreleasepool {
        IVLyricsSpotifyBootstrap();
    }
}
