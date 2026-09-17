#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The small, transparent title strip used by the home surface.  It deliberately
/// lives in the content view so the background stage can continue underneath it.
/// The view owns no application state; the host injects the title/subtitle and
/// receives normal window actions through the represented window.
@interface ZZWindowChromeView : NSView

@property (nonatomic, weak, nullable) NSWindow *representedWindow;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *subtitleText;
@property (nonatomic, strong) NSFont *titleFont;
@property (nonatomic, strong) NSFont *subtitleFont;
@property (nonatomic, strong) NSColor *titleColor;
@property (nonatomic, strong) NSColor *subtitleColor;
@property (nonatomic, strong) NSColor *trafficColor;

@end

NS_ASSUME_NONNULL_END
