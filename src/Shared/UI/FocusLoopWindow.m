//
//  FocusLoopWindow.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "FocusLoopWindow.h"
#import "UIThemeSupport.h"

@implementation FocusLoopWindow
// R9 防抢焦点（P0）：测试模式（ZZIsTestMode，覆盖全部 UI/layout/screenshot/memory 测试入口）
// 下，任何 makeKeyAndOrderFront / orderFrontRegardless / becomeKey / becomeMain 一律降级为
// orderBack，窗口永远不成为 key/main，也不得置顶遮挡用户前台 App。
- (void)makeKeyAndOrderFront:(id)sender {
    if(ZZIsTestMode()){
        ZZOrderTestWindowBehindFrontApp(self);
        return;
    }
    [super makeKeyAndOrderFront:sender];
}
- (void)orderFrontRegardless {
    if(ZZIsTestMode()){
        ZZOrderTestWindowBehindFrontApp(self);
        return;
    }
    [super orderFrontRegardless];
}
- (BOOL)canBecomeKeyWindow { return ZZIsTestMode() ? NO : [super canBecomeKeyWindow]; }
- (BOOL)canBecomeMainWindow { return ZZIsTestMode() ? NO : [super canBecomeMainWindow]; }
- (BOOL)handleEdgeResizeIfNeeded:(NSEvent *)event {
    if (event.type != NSEventTypeLeftMouseDown || !(self.styleMask & NSWindowStyleMaskResizable)) return NO;
    NSPoint p = event.locationInWindow;
    NSView *contentView = self.contentView;
    if (!contentView) return NO;
    NSRect content = contentView.frame;
    // locationInWindow 也包含标题栏坐标。旧代码只比较 y >= 内容高度-7，
    // 因而把整个标题栏误判为顶部缩放边缘，抢走系统窗口拖动并把位置拉回。
    // 自定义缩放只允许命中真正的内容区；标题栏必须完整交给 AppKit 原生拖动。
    if (!NSPointInRect(p, content)) return NO;
    // Full-size content view extends beneath the system titlebar.  The first
    // 40pt are our own ZZWindowChromeView, whose edge gestures must remain
    // available for window dragging/traffic controls rather than being stolen
    // by the legacy manual resize loop.  NSWindow coordinates are bottom-left
    // based, so the custom strip is the top 40pt of contentView.frame.
    static const CGFloat kZZCustomTitlebarHeight = 40.0;
    if (p.y >= NSMaxY(content) - kZZCustomTitlebarHeight) return NO;
    CGFloat edge = 7.0;
    CGFloat localX = p.x - NSMinX(content);
    CGFloat localY = p.y - NSMinY(content);
    BOOL left = localX <= edge;
    BOOL right = localX >= NSWidth(content) - edge;
    BOOL bottom = localY <= edge;
    BOOL top = localY >= NSHeight(content) - edge;
    if (!left && !right && !bottom && !top) return NO;

    NSPoint startMouse = NSEvent.mouseLocation;
    NSRect startFrame = self.frame;
    while (YES) {
        NSEvent *next = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                           untilDate:[NSDate distantFuture]
                                              inMode:NSEventTrackingRunLoopMode
                                             dequeue:YES];
        if (!next || next.type == NSEventTypeLeftMouseUp) break;
        NSPoint mouse = NSEvent.mouseLocation;
        CGFloat dx = mouse.x - startMouse.x;
        CGFloat dy = mouse.y - startMouse.y;
        NSRect frame = startFrame;
        if (left) { frame.origin.x += dx; frame.size.width -= dx; }
        if (right) frame.size.width += dx;
        if (bottom) { frame.origin.y += dy; frame.size.height -= dy; }
        if (top) frame.size.height += dy;
        NSSize minimum = self.minSize;
        if (frame.size.width < minimum.width) {
            if (left) frame.origin.x -= minimum.width - frame.size.width;
            frame.size.width = minimum.width;
        }
        if (frame.size.height < minimum.height) {
            if (bottom) frame.origin.y -= minimum.height - frame.size.height;
            frame.size.height = minimum.height;
        }
        [self setFrame:frame display:YES];
    }
    return YES;
}

- (void)sendEvent:(NSEvent *)event {
    if ([self handleEdgeResizeIfNeeded:event]) return;
    NSEventModifierFlags blocked = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    if (event.type == NSEventTypeKeyDown && event.keyCode == 48 && !(event.modifierFlags & blocked)) {
        id responder = self.firstResponder;
        NSView *current = [responder isKindOfClass:NSView.class] ? responder : nil;
        if ([responder isKindOfClass:NSTextView.class]) {
            id delegate = [(NSTextView *)responder delegate];
            if ([delegate isKindOfClass:NSView.class]) current = delegate;
        }
        BOOL backwards = (event.modifierFlags & NSEventModifierFlagShift) != 0;
        NSView *candidate = backwards ? current.previousKeyView : current.nextKeyView;
        if (!candidate) candidate = self.initialFirstResponder;
        for (NSInteger guard = 0; candidate && guard < 64; guard++) {
            BOOL enabled = ![candidate isKindOfClass:NSControl.class] || [(NSControl *)candidate isEnabled];
            if (candidate.acceptsFirstResponder && !candidate.hidden && enabled) break;
            candidate = backwards ? candidate.previousKeyView : candidate.nextKeyView;
        }
        if (candidate && [self makeFirstResponder:candidate]) return;
    }
    [super sendEvent:event];
}
@end
