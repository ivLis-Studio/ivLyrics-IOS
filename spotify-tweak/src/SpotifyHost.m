#import "SpotifyHost.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#if IVL_HOST_TESTING
#import "HostUIKitFixture.h"
#else
#import <UIKit/UIKit.h>
#endif

extern void IVLyricsSpotifyUISetSeekHandler(void (*handler)(int64_t positionMs));

@protocol IVLHostUI <NSObject>
+ (instancetype)shared;
- (void)updateStateJSON:(NSString *)json;
- (void)attachCardToView:(UIView *)view;
- (void)attachFullscreenToView:(UIView *)view;
- (void)detachFromView:(UIView *)view;
- (void)hostDisconnected;
- (BOOL)hasTrackAndLyrics;
- (void)setOnReadyChanged:(void (^)(BOOL))callback;
- (void)presentFromViewController:(UIViewController *)controller;
@end

static NSString *const IVLStatefulClass = @"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation";
static NSString *const IVLCardClass = @"_TtC22Lyrics_CardElementImpl8CardView";
static NSString *const IVLFullscreenClass = @"_TtC32Lyrics_FullscreenElementPageImpl14FullscreenView";
static NSString *const IVLFullscreenLyricsClass = @"_TtC32Lyrics_FullscreenElementPageImpl10LyricsView";
static NSString *const IVLNPVClass = @"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController";
static NSString *const IVLOwnedViewPrefix = @"ivlyrics.spotify.";
static BOOL IVLInstalled;
static __weak id IVLPlayer;
static NSString *IVLPlayerTrackID;
static double IVLDurationSeconds;
static uint64_t IVLSequence;
static uint64_t IVLDeliveredSequence;
static NSLock *IVLSequenceLock;
static NSHashTable<UIView *> *IVLContainers;
static id<IVLHostUI> IVLUI;
static IMP IVLOriginalState, IVLOriginalAddObserver, IVLOriginalStateChanged;
static IMP IVLOriginalCardLayout, IVLOriginalFullscreenLayout, IVLOriginalAppear;
static char IVLVisibilityKey, IVLFullscreenRegionKey;
#if !IVL_HOST_TESTING
static char IVLEntryKey;
#endif

@interface IVLNativeVisibility : NSObject
@property(nonatomic, strong) NSMapTable<UIView *, NSNumber *> *values;
@end
@implementation IVLNativeVisibility
- (instancetype)init {
    if ((self = [super init])) _values = [NSMapTable weakToStrongObjectsMapTable];
    return self;
}
@end

@interface IVLFullscreenRegion : NSObject
@property(nonatomic, weak) UIView *view;
@end
@implementation IVLFullscreenRegion @end

static id IVLObject(id target, NSString *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector));
}
static double IVLDouble(id target, NSString *selector) {
    return ((double (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector));
}
static BOOL IVLBool(id target, NSString *selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector));
}
static NSString *IVLText(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || [value length] > limit) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static BOOL IVLAlphanumeric(NSString *value, NSUInteger count) {
    if (value.length != count) return NO;
    return [value rangeOfCharacterFromSet:
            [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"] invertedSet]].location == NSNotFound;
}

/// Only allowlisted song metadata crosses the UI boundary. No account or token fields.
static NSDictionary *IVLSnapshot(id state) {
    if (![state isKindOfClass:NSClassFromString(@"SPTPlayerState")]) return nil;
    id track = IVLObject(state, @"track");
    if (![track isKindOfClass:NSClassFromString(@"SPTPlayerTrack")]) return nil;
    id uri = IVLObject(track, @"URI");
    if (![uri isKindOfClass:NSURL.class]) return nil;
    NSString *uriString = [uri absoluteString];
    if (![uriString hasPrefix:@"spotify:track:"]) return nil;
    NSString *spotifyID = [uriString substringFromIndex:@"spotify:track:".length];
    if (!IVLAlphanumeric(spotifyID, 22)) return nil;
    NSString *title = IVLText(IVLObject(track, @"trackTitle"), 4096);
    NSString *artist = IVLText(IVLObject(track, @"artistName"), 4096);
    if (!title.length || !artist.length) return nil;
    NSString *album = IVLText(IVLObject(track, @"albumTitle"), 4096);
    id metadata = IVLObject(track, @"metadata");
    NSString *isrc = [metadata isKindOfClass:NSDictionary.class] ? IVLText(metadata[@"isrc"], 12) : @"";
    if (!IVLAlphanumeric(isrc, 12)) isrc = @"";
    double duration = IVLDouble(state, @"duration");
    BOOL paused = IVLBool(state, @"isPaused");
    double position = IVLDouble(state, paused ? @"positionAsOfTimestamp" : @"position");
    double speed = IVLDouble(state, @"playbackSpeed");
    // Seconds are the inferred SPTPlayerState / Esperanto convention; the ABI
    // proves double, not the unit. Real-device confirmation is still required.
    // JSON uses milliseconds.
    // The cap also keeps hostile/non-finite host values outside integer conversion.
    duration = isfinite(duration) && duration >= 0 && duration <= 7 * 86400 ? duration : 0;
    position = isfinite(position) && position >= 0 ? position : 0;
    position = MIN(position, duration > 0 ? duration : 7 * 86400);
    speed = isfinite(speed) && speed > 0 && speed <= 8 ? speed : 1;
    BOOL playing = !paused && IVLBool(state, @"isPlaying") && !IVLBool(state, @"isLoading");
    return @{@"title": title, @"artist": artist, @"album": album, @"spotifyID": spotifyID,
             @"isrc": isrc, @"durationMs": @((int64_t)llround(duration * 1000)),
             @"positionMs": @((int64_t)llround(position * 1000)), @"playing": @(playing), @"speed": @(speed)};
}

static void IVLOnMain(void (^work)(void)) {
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static BOOL IVLIsOwnedView(UIView *view) {
    return [view.accessibilityIdentifier hasPrefix:IVLOwnedViewPrefix];
}

static void IVLRestoreNativeVisibility(UIView *container) {
    IVLNativeVisibility *saved = objc_getAssociatedObject(container, &IVLVisibilityKey);
    for (UIView *child in saved.values.keyEnumerator) child.hidden = [[saved.values objectForKey:child] boolValue];
    objc_setAssociatedObject(container, &IVLVisibilityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IVLApplyNativeVisibility(UIView *container) {
    BOOL hasOwnView = NO;
    for (UIView *child in container.subviews) if (IVLIsOwnedView(child)) hasOwnView = YES;
    BOOL hide = hasOwnView && [IVLUI hasTrackAndLyrics];
    IVLNativeVisibility *saved = objc_getAssociatedObject(container, &IVLVisibilityKey);
    if (hide) {
        if (!saved) {
            saved = [IVLNativeVisibility new];
            objc_setAssociatedObject(container, &IVLVisibilityKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (UIView *child in container.subviews) {
            if (IVLIsOwnedView(child)) continue;
            if (![saved.values objectForKey:child]) [saved.values setObject:@(child.hidden) forKey:child];
            child.hidden = YES;
        }
    } else if (saved) {
        IVLRestoreNativeVisibility(container);
    }
}

static void IVLRefreshContainers(void) {
    for (UIView *view in IVLContainers.allObjects) IVLApplyNativeVisibility(view);
}

static void IVLPublish(id player, id state) {
    [IVLSequenceLock lock];
    uint64_t sequence = ++IVLSequence;
    [IVLSequenceLock unlock];
    NSDictionary *snapshot = nil;
    @try { snapshot = IVLSnapshot(state); }
    @catch (__unused NSException *exception) { /* Fail back to the native screen. */ }
    // Never retain a host player beyond this callback; each UI seek checks it again.
    __weak id weakPlayer = [player isKindOfClass:NSClassFromString(@"SPTEsperantoPlayer")] ? player : nil;
    IVLOnMain(^{
        if (sequence < IVLDeliveredSequence) return;
        IVLDeliveredSequence = sequence;
        if (!snapshot) {
            IVLPlayer = nil;
            IVLPlayerTrackID = nil;
            IVLDurationSeconds = 0;
            [IVLUI hostDisconnected];
            IVLRefreshContainers();
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
        if (!data) return;
        // A Swift wrapper can deliver state without itself being the Esperanto
        // seek target. Keep a known weak target only while the track is unchanged.
        if (weakPlayer || ![IVLPlayerTrackID isEqual:snapshot[@"spotifyID"]]) IVLPlayer = weakPlayer;
        IVLPlayerTrackID = snapshot[@"spotifyID"];
        IVLDurationSeconds = [snapshot[@"durationMs"] doubleValue] / 1000;
        [IVLUI updateStateJSON:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        IVLRefreshContainers();
    });
}

static id IVLState(id self, SEL selector) {
    id state = ((id (*)(id, SEL))IVLOriginalState)(self, selector);
    IVLPublish(self, state);
    return state;
}
static void IVLAddObserver(id self, SEL selector, id observer) {
    ((void (*)(id, SEL, id))IVLOriginalAddObserver)(self, selector, observer);
    // Call the saved original getter to avoid recursively publishing through our hook.
    id state = ((id (*)(id, SEL))IVLOriginalState)(self, @selector(state));
    IVLPublish(self, state);
}
static void IVLStateChanged(id self, SEL selector, id player, id state) {
    ((void (*)(id, SEL, id, id))IVLOriginalStateChanged)(self, selector, player, state);
    IVLPublish(player, state);
}
static void IVLAttach(UIView *view, BOOL fullscreen) {
    IVLOnMain(^{
        [IVLContainers addObject:view];
        if (fullscreen) [IVLUI attachFullscreenToView:view];
        else [IVLUI attachCardToView:view];
        IVLApplyNativeVisibility(view);
    });
}
static void IVLCardLayout(UIView *self, SEL selector) {
    ((void (*)(id, SEL))IVLOriginalCardLayout)(self, selector);
    IVLAttach(self, NO);
}

/// The inspected FullscreenView also owns header, playback controls and footer.
/// Only its verified lyrics-content UIView may be replaced. Ambiguous/truncated
/// hierarchies fail back to native UI; never guess using ivars or KVC.
static UIView *IVLFindFullscreenLyrics(UIView *root) {
    Class lyricsClass = NSClassFromString(IVLFullscreenLyricsClass);
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:root];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray arrayWithObject:@0];
    UIView *found = nil;
    NSUInteger visited = 0;
    for (NSUInteger cursor = 0; cursor < views.count; cursor++) {
        UIView *view = views[cursor];
        if (IVLIsOwnedView(view)) continue;
        if (++visited > 256) return nil;
        NSUInteger depth = depths[cursor].unsignedIntegerValue;
        if (object_getClass(view) == lyricsClass) {
            if (found) return nil;
            found = view;
        }
        for (UIView *child in view.subviews) {
            if (IVLIsOwnedView(child)) continue;
            if (depth >= 8 || views.count >= 256) return nil;
            [views addObject:child];
            [depths addObject:@(depth + 1)];
        }
    }
    return found;
}

static void IVLFullscreenLayout(UIView *self, SEL selector) {
    ((void (*)(id, SEL))IVLOriginalFullscreenLayout)(self, selector);
    IVLOnMain(^{
        UIView *content = IVLFindFullscreenLyrics(self);
        IVLFullscreenRegion *previous = objc_getAssociatedObject(self, &IVLFullscreenRegionKey);
        if (previous.view && previous.view != content) {
            IVLRestoreNativeVisibility(previous.view);
            [IVLUI detachFromView:previous.view];
            [IVLContainers removeObject:previous.view];
        }
        if (!content) {
            objc_setAssociatedObject(self, &IVLFullscreenRegionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        IVLFullscreenRegion *region = [IVLFullscreenRegion new]; region.view = content;
        objc_setAssociatedObject(self, &IVLFullscreenRegionKey, region, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IVLAttach(content, YES);
    });
}

#if !IVL_HOST_TESTING
@interface IVLEntryAction : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, weak) UIButton *button;
- (void)open;
- (void)drag:(UIPanGestureRecognizer *)gesture;
@end
@implementation IVLEntryAction
- (void)open {
    UIViewController *controller = self.controller;
    if (controller) [IVLUI presentFromViewController:controller];
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    UIButton *button = self.button;
    UIView *parent = button.superview;
    if (!parent) return;
    CGPoint delta = [gesture translationInView:parent];
    CGRect safe = UIEdgeInsetsInsetRect(parent.bounds, parent.safeAreaInsets);
    CGFloat halfWidth = CGRectGetWidth(button.bounds) / 2, halfHeight = CGRectGetHeight(button.bounds) / 2;
    button.center = CGPointMake(MIN(MAX(button.center.x + delta.x, CGRectGetMinX(safe) + halfWidth), CGRectGetMaxX(safe) - halfWidth),
                                MIN(MAX(button.center.y + delta.y, CGRectGetMinY(safe) + halfHeight), CGRectGetMaxY(safe) - halfHeight));
    [gesture setTranslation:CGPointZero inView:parent];
}
@end

static void IVLAddEntry(UIViewController *controller) {
    if (objc_getAssociatedObject(controller, &IVLEntryKey)) return;
    IVLEntryAction *action = [IVLEntryAction new];
    action.controller = controller;
    if (controller.navigationController && !controller.navigationController.navigationBarHidden) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"ivLyrics" style:UIBarButtonItemStylePlain target:action action:@selector(open)];
        item.accessibilityIdentifier = @"ivLyricsSpotify.entry";
        NSArray *existing = controller.navigationItem.rightBarButtonItems ?: @[];
        controller.navigationItem.rightBarButtonItems = [existing arrayByAddingObject:item];
    } else {
        UIView *view = controller.view;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"ivLyrics" forState:UIControlStateNormal];
        button.accessibilityIdentifier = @"ivLyricsSpotify.entry";
        button.accessibilityLabel = @"Open ivLyrics and import LRC";
        button.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.95];
        button.layer.cornerRadius = 18;
        button.frame = CGRectMake(MAX(8, CGRectGetWidth(view.bounds) - 96), MAX(8, CGRectGetHeight(view.bounds) - view.safeAreaInsets.bottom - 68), 88, 36);
        button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        [button addTarget:action action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:action action:@selector(drag:)]];
        [view addSubview:button];
        action.button = button;
    }
    objc_setAssociatedObject(controller, &IVLEntryKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#endif

static void IVLAppear(UIViewController *self, SEL selector, BOOL animated) {
    ((void (*)(id, SEL, BOOL))IVLOriginalAppear)(self, selector, animated);
#if !IVL_HOST_TESTING
    // Allow the original presentation to finish adding its own controls first.
    __weak UIViewController *weakController = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if (weakController) IVLAddEntry(weakController); });
#endif
}

typedef struct { const char *className; const char *selector; const char *encoding; } IVLRequirement;
static const IVLRequirement IVLRequirements[] = {
    {"SPTEsperantoPlayer", "state", "@16@0:8"},
    {"SPTEsperantoPlayer", "addPlayerObserver:", "v24@0:8@16"},
    {"SPTEsperantoPlayer", "removePlayerObserver:", "v24@0:8@16"},
    {"SPTEsperantoPlayer", "seekTo:", "@24@0:8d16"},
    {"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation", "player:stateDidChange:", "v32@0:8@16@24"},
    {"SPTPlayerState", "track", "@16@0:8"}, {"SPTPlayerState", "position", "d16@0:8"},
    {"SPTPlayerState", "positionAsOfTimestamp", "d16@0:8"}, {"SPTPlayerState", "duration", "d16@0:8"},
    {"SPTPlayerState", "playbackSpeed", "d16@0:8"}, {"SPTPlayerState", "isPaused", "B16@0:8"},
    {"SPTPlayerState", "isPlaying", "B16@0:8"}, {"SPTPlayerState", "isLoading", "B16@0:8"},
    {"SPTPlayerTrack", "URI", "@16@0:8"}, {"SPTPlayerTrack", "trackTitle", "@16@0:8"},
    {"SPTPlayerTrack", "artistName", "@16@0:8"}, {"SPTPlayerTrack", "albumTitle", "@16@0:8"},
    {"SPTPlayerTrack", "metadata", "@16@0:8"},
    {"_TtC22Lyrics_CardElementImpl8CardView", "layoutSubviews", "v16@0:8"},
    {"_TtC32Lyrics_FullscreenElementPageImpl14FullscreenView", "layoutSubviews", "v16@0:8"},
    {"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController", "viewWillAppear:", "v20@0:8B16"},
};

static void IVLReplace(NSString *className, NSString *selectorName, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    IMP previous = method_getImplementation(method);
    *original = previous;
    // An inherited implementation must be overridden on this class only.
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) *original = previous;
    else *original = method_setImplementation(method, replacement);
}

static void IVLSeek(int64_t positionMs) {
    IVLOnMain(^{
        id player = IVLPlayer;
        if (!player || positionMs < 0 || IVLDurationSeconds <= 0) return;
        double seconds = MIN((double)positionMs / 1000, IVLDurationSeconds);
        // The inspected Esperanto method returns an object; the Swift wrapper returns void.
        @try {
            __unused id result = ((id (*)(id, SEL, double))objc_msgSend)(player, @selector(seekTo:), seconds);
        } @catch (__unused NSException *exception) {
            IVLPlayer = nil;
            NSLog(@"[ivLyrics] Host seek unavailable.");
        }
    });
}

BOOL IVLyricsSpotifyInstallHostHooks(void) {
    // UIKit and the Swift UI singleton are main-thread confined.
    if (!NSThread.isMainThread) return NO;
    @synchronized(NSClassFromString(@"NSObject")) {
        if (IVLInstalled) return YES;
#if IVL_HOST_TESTING
        extern NSDictionary *IVLHostTestBundleInfo(void);
        NSDictionary *info = IVLHostTestBundleInfo();
#else
        if (@available(iOS 17.0, *)) {} else { return NO; }
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
#endif
        // Sideloaders can rewrite the identifier; executable/version/ABI stay exact.
        if (![info[@"CFBundleShortVersionString"] isEqual:@"9.1.60"] ||
            ![info[@"CFBundleVersion"] isEqual:@"916001969"] ||
            ![info[@"CFBundleExecutable"] isEqual:@"Spotify"]) return NO;
        for (NSUInteger index = 0; index < sizeof(IVLRequirements) / sizeof(IVLRequirements[0]); index++) {
            IVLRequirement r = IVLRequirements[index];
            Method method = class_getInstanceMethod(objc_getClass(r.className), sel_registerName(r.selector));
            if (!method || strcmp(method_getTypeEncoding(method), r.encoding) != 0) return NO;
        }
        Class lyricsViewClass = NSClassFromString(IVLFullscreenLyricsClass);
        if (!lyricsViewClass || class_getSuperclass(lyricsViewClass) != UIView.class) return NO;
        Class uiClass = NSClassFromString(@"IVLyricsSpotifyUI");
        if (![uiClass respondsToSelector:@selector(shared)]) return NO;
        id<IVLHostUI> ui = [(id<IVLHostUI>)uiClass shared];
        for (NSString *name in @[@"updateStateJSON:", @"attachCardToView:", @"attachFullscreenToView:", @"detachFromView:",
                                 @"hostDisconnected", @"hasTrackAndLyrics", @"setOnReadyChanged:", @"presentFromViewController:"]) {
            if (![ui respondsToSelector:NSSelectorFromString(name)]) return NO;
        }
        IVLUI = ui;
        IVLSequenceLock = [NSLock new];
        IVLContainers = [NSHashTable weakObjectsHashTable];
        [ui setOnReadyChanged:^(__unused BOOL ready) { IVLOnMain(^{ IVLRefreshContainers(); }); }];
        IVLyricsSpotifyUISetSeekHandler(IVLSeek);
        IVLReplace(@"SPTEsperantoPlayer", @"state", (IMP)IVLState, &IVLOriginalState);
        IVLReplace(@"SPTEsperantoPlayer", @"addPlayerObserver:", (IMP)IVLAddObserver, &IVLOriginalAddObserver);
        IVLReplace(IVLStatefulClass, @"player:stateDidChange:", (IMP)IVLStateChanged, &IVLOriginalStateChanged);
        IVLReplace(IVLCardClass, @"layoutSubviews", (IMP)IVLCardLayout, &IVLOriginalCardLayout);
        IVLReplace(IVLFullscreenClass, @"layoutSubviews", (IMP)IVLFullscreenLayout, &IVLOriginalFullscreenLayout);
        IVLReplace(IVLNPVClass, @"viewWillAppear:", (IMP)IVLAppear, &IVLOriginalAppear);
        IVLInstalled = YES;
        return YES;
    }
}

BOOL IVLyricsSpotifyHostIsAvailable(void) { return IVLInstalled; }
