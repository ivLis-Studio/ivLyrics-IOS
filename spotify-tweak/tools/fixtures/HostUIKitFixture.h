#import <Foundation/Foundation.h>

// A small Foundation-only surface for running the production host adapter on macOS.
// It does not pretend to validate UIKit layout or actual Spotify presentation.
@interface UIView : NSObject
@property(nonatomic) BOOL hidden;
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@property(nonatomic, readonly) NSArray<UIView *> *subviews;
@property(nonatomic) NSUInteger layoutCalls;
- (void)addSubview:(UIView *)view;
- (void)removeSubview:(UIView *)view;
- (void)layoutSubviews;
@end

@interface UIViewController : NSObject
@property(nonatomic) NSUInteger appearanceCalls;
- (void)viewWillAppear:(BOOL)animated;
@end
