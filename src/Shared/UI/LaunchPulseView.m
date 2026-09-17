//
//  LaunchPulseView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "LaunchPulseView.h"
#import "UIThemeSupport.h"

@implementation LaunchPulseView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGFloat w = NSWidth(b), h = NSHeight(b);
    // Transparent grid and radar arcs: visible as a subtle HUD without
    // obscuring the page underneath.
    [[RC(.34,.26,1.0,.045) colorWithAlphaComponent:.045] setStroke];
    for (NSInteger i=1; i<8; i++) {
        CGFloat x = w * i / 8.0;
        NSBezierPath *v = [NSBezierPath bezierPath];
        [v moveToPoint:NSMakePoint(x, 0)]; [v lineToPoint:NSMakePoint(x, h)];
        v.lineWidth = .45; [v stroke];
    }
    for (NSInteger i=1; i<6; i++) {
        CGFloat y = h * i / 6.0;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(0, y)]; [line lineToPoint:NSMakePoint(w, y)];
        line.lineWidth = .45; [line stroke];
    }
    NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
    for (NSInteger i=0; i<3; i++) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-(90+i*76), c.y-(90+i*76), 180+i*152, 180+i*152)];
        ring.lineWidth = (i==0 ? 1.0 : .6);
        [[RC(i==0?.38:.52, i==0?.70:.35, 1.0, i==0?.18:.10) colorWithAlphaComponent:i==0?.18:.10] setStroke];
        [ring stroke];
    }
}
@end
