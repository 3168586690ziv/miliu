//
//  WindowResizeGripView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "WindowResizeGripView.h"

@implementation WindowResizeGripView
- (BOOL)isOpaque { return NO; }
- (void)resetCursorRects {
    [super resetCursorRects];
    BOOL horizontal = (self.directions & (WindowResizeLeft | WindowResizeRight)) != 0;
    BOOL vertical = (self.directions & (WindowResizeTop | WindowResizeBottom)) != 0;
    NSCursor *cursor = horizontal && vertical ? NSCursor.crosshairCursor :
                       (horizontal ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor);
    [self addCursorRect:self.bounds cursor:cursor];
}
- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.window;
    if (!window) return;
    NSPoint startMouse = NSEvent.mouseLocation;
    NSRect startFrame = window.frame;
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
        if (self.directions & WindowResizeLeft) { frame.origin.x += dx; frame.size.width -= dx; }
        if (self.directions & WindowResizeRight) frame.size.width += dx;
        if (self.directions & WindowResizeBottom) { frame.origin.y += dy; frame.size.height -= dy; }
        if (self.directions & WindowResizeTop) frame.size.height += dy;
        NSSize minimum = window.minSize;
        if (frame.size.width < minimum.width) {
            if (self.directions & WindowResizeLeft) frame.origin.x -= minimum.width - frame.size.width;
            frame.size.width = minimum.width;
        }
        if (frame.size.height < minimum.height) {
            if (self.directions & WindowResizeBottom) frame.origin.y -= minimum.height - frame.size.height;
            frame.size.height = minimum.height;
        }
        [window setFrame:frame display:YES];
    }
}
@end
