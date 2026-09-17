//
//  HoverableControl.m — 模块 09
//
#import "HoverableControl.h"

@interface HoverableControl ()
@property (nonatomic, readwrite) BOOL hovered;
@property (nonatomic, strong, nullable) NSTrackingArea *hoverArea;
@property (nonatomic, assign) BOOL pressed;
@end

@implementation HoverableControl

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) { [self removeTrackingArea:self.hoverArea]; self.hoverArea = nil; }
    // NSTrackingInVisibleRect：随可见区域自动更新，避免滚动/缩放后 rect 失配。
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveInActiveApp |
                                 NSTrackingInVisibleRect;
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                  options:opts
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}

- (void)mouseEntered:(NSEvent *)event { [self beginHover]; }
- (void)mouseExited:(NSEvent *)event  { [self endHover]; }

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEnabled) return;
    self.pressed = YES;
    [self hoverStateChanged];
}
- (void)mouseUp:(NSEvent *)event {
    self.pressed = NO;
    [self hoverStateChanged];
    if (self.isEnabled && self.target && self.action) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

- (void)beginHover {
    if (!self.isEnabled) return;
    if (self.hovered) return;
    self.hovered = YES;
    [self hoverStateChanged];
}

- (void)endHover {
    if (!self.hovered) return;
    self.hovered = NO;
    [self hoverStateChanged];
}

- (void)clearHoverForWindowChange {
    self.pressed = NO;
    [self endHover];
}

// 窗口失焦、移除时清除 hover（防止粘住）
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [self clearHoverForWindowChange];
        return;
    }
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    [nc addObserver:self selector:@selector(windowResigned:)
               name:NSWindowDidResignKeyNotification object:self.window];
}

- (void)windowResigned:(NSNotification *)note {
    [self clearHoverForWindowChange];
}

- (ControlVisualState)visualState {
    if (!self.isEnabled) return ControlVisualDisabled;
    if (self.pressed)    return ControlVisualPressed;
    if (self.selected)   return ControlVisualSelected;
    if (self.hovered)    return ControlVisualHovered;
    if (self.window.firstResponder == self) return ControlVisualFocused;
    return ControlVisualNormal;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self hoverStateChanged];
}

- (void)hoverStateChanged {
    self.needsDisplay = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
