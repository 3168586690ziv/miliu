#import "ZZWindowChromeView.h"

@interface ZZWindowChromeView ()
@end

@implementation ZZWindowChromeView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _titleText = @"7zz";
    _subtitleText = @"个人高级控制中心";
    _titleFont = [NSFont fontWithName:@"Noteworthy-Light" size:14.0] ?: [NSFont systemFontOfSize:14.0 weight:NSFontWeightMedium];
    _subtitleFont = [NSFont fontWithName:@"HanziPenSC-W3" size:12.0] ?: [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    _titleColor = [NSColor colorWithSRGBRed:0.941 green:0.894 blue:0.953 alpha:1.0];
    _subtitleColor = [NSColor colorWithSRGBRed:0.702 green:0.612 blue:0.737 alpha:1.0];
    _trafficColor = [NSColor colorWithSRGBRed:0.424 green:0.380 blue:0.443 alpha:1.0];
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.identifier = @"ZZHomeTitlebar";
    self.accessibilityIdentifier = @"ZZHomeTitlebar";
    self.accessibilityLabel = @"7zz 标题栏";
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setTitleText:(NSString *)titleText { _titleText = [titleText copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setSubtitleText:(NSString *)subtitleText { _subtitleText = [subtitleText copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setTitleFont:(NSFont *)titleFont { _titleFont = titleFont ?: [NSFont systemFontOfSize:14.0]; [self setNeedsDisplay:YES]; }
- (void)setSubtitleFont:(NSFont *)subtitleFont { _subtitleFont = subtitleFont ?: [NSFont systemFontOfSize:12.0]; [self setNeedsDisplay:YES]; }
- (void)setTitleColor:(NSColor *)titleColor { _titleColor = titleColor ?: NSColor.whiteColor; [self setNeedsDisplay:YES]; }
- (void)setSubtitleColor:(NSColor *)subtitleColor { _subtitleColor = subtitleColor ?: NSColor.whiteColor; [self setNeedsDisplay:YES]; }
- (void)setTrafficColor:(NSColor *)trafficColor { _trafficColor = trafficColor ?: NSColor.whiteColor; [self setNeedsDisplay:YES]; }

- (void)drawRect:(__unused NSRect)dirtyRect {
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: self.titleFont,
        NSForegroundColorAttributeName: self.titleColor,
        NSShadowAttributeName: ({ NSShadow *s = [NSShadow new]; s.shadowColor = [NSColor colorWithWhite:0 alpha:.78]; s.shadowBlurRadius = 3; s.shadowOffset = NSMakeSize(0, 1); s; })
    };
    [self.titleText drawAtPoint:NSMakePoint(57.0, 12.0) withAttributes:titleAttrs];

    NSDictionary *subtitleAttrs = @{
        NSFontAttributeName: self.subtitleFont,
        NSForegroundColorAttributeName: self.subtitleColor,
        NSShadowAttributeName: ({ NSShadow *s = [NSShadow new]; s.shadowColor = [NSColor colorWithWhite:0 alpha:.78]; s.shadowBlurRadius = 3; s.shadowOffset = NSMakeSize(0, 1); s; })
    };
    NSSize size = [self.subtitleText sizeWithAttributes:subtitleAttrs];
    CGFloat x = MAX(180.0, NSWidth(self.bounds) - 18.0 - size.width);
    [self.subtitleText drawAtPoint:NSMakePoint(x, 13.0) withAttributes:subtitleAttrs];
}

- (NSView *)hitTest:(NSPoint)point {
    // The controls are owned by NSWindow.standardWindowButton:.  Resolve their
    // actual frames at runtime: AppKit may move or resize them for appearance,
    // safe-area and fullscreen transitions. Returning nil for those rectangles
    // lets the window's native titlebar button receive the event; the rest of
    // this strip remains draggable through the window.
    NSWindow *window=self.representedWindow ?: self.window;
    for(NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
        NSButton *button=[window standardWindowButton:kind.integerValue];
        if(!button || button.hidden || !button.enabled) continue;
        NSPoint windowPoint=[self convertPoint:point toView:nil];
        NSRect buttonRect=[button convertRect:button.bounds toView:nil];
        if(NSPointInRect(windowPoint, NSInsetRect(buttonRect,-4.0,-4.0))) return nil;
    }
    return NSPointInRect(point, self.bounds) ? self : nil;
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.representedWindow ?: self.window;
    if (window) [window performWindowDragWithEvent:event];
}

@end
