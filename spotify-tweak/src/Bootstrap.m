#import <Foundation/Foundation.h>
#import "SpotifyHost.h"

extern void IVLyricsSpotifyBootstrap(void);
extern void IVLyricsSpotifyHostAvailabilityChanged(bool available);

__attribute__((constructor)) static void IVLyricsSpotifyLoad(void) {
    @autoreleasepool {
        IVLyricsSpotifyBootstrap();
        // Wait until Objective-C/Swift classes and the main run loop are ready.
        // The adapter leaves the host untouched when any required guard fails.
        dispatch_async(dispatch_get_main_queue(), ^{
            IVLyricsSpotifyHostAvailabilityChanged(IVLyricsSpotifyInstallHostHooks());
        });
    }
}
