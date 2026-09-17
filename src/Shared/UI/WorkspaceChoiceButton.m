//
//  WorkspaceChoiceButton.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "WorkspaceChoiceButton.h"
#import "UIThemeSupport.h"

@implementation WorkspaceChoiceButton
- (BOOL)acceptsFirstResponder{return YES;}
- (void)updateTrackingAreas{[super updateTrackingAreas];if(self.hoverArea)[self removeTrackingArea:self.hoverArea];self.hoverArea=[[NSTrackingArea alloc]initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways owner:self userInfo:nil];[self addTrackingArea:self.hoverArea];}
- (void)mouseEntered:(NSEvent *)event{self.hovered=YES;CABasicAnimation *glow=[CABasicAnimation animationWithKeyPath:@"shadowOpacity"];glow.fromValue=@.48;glow.toValue=@.72;glow.duration=.26;glow.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];[self.layer addAnimation:glow forKey:@"hoverGlow"];self.layer.shadowOpacity=.72;self.needsDisplay=YES;}
- (void)mouseExited:(NSEvent *)event{self.hovered=NO;CABasicAnimation *glow=[CABasicAnimation animationWithKeyPath:@"shadowOpacity"];glow.fromValue=@.72;glow.toValue=@.48;glow.duration=.32;glow.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];[self.layer addAnimation:glow forKey:@"hoverGlow"];self.layer.shadowOpacity=.48;self.needsDisplay=YES;}
- (void)viewDidMoveToWindow{[super viewDidMoveToWindow];if(!self.window){self.hovered=NO;self.needsDisplay=YES;}}
- (void)drawRect:(NSRect)dirtyRect{
    NSRect b=NSInsetRect(self.bounds,3,3);CGFloat hover=self.hovered?1:0;NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:b xRadius:25 yRadius:25];
    NSColor *safeAccent=self.accent?:NSColor.whiteColor;
    NSGradient *fill=[[NSGradient alloc]initWithColors:@[RC(.055,.052,.10,.98),RC(.018,.022,.042,.98),[safeAccent colorWithAlphaComponent:(.10+.10*hover)]]];[fill drawInBezierPath:shape angle:-56];shape.lineWidth=1.8+.45*hover;[[safeAccent colorWithAlphaComponent:(.88+.10*hover)]setStroke];[shape stroke];
    NSBezierPath *top=[NSBezierPath bezierPath];[top moveToPoint:NSMakePoint(38,NSMaxY(b)-1)];[top curveToPoint:NSMakePoint(NSMaxX(b)-38,NSMaxY(b)-1) controlPoint1:NSMakePoint(110,NSMaxY(b)+3) controlPoint2:NSMakePoint(NSMaxX(b)-110,NSMaxY(b)+3)];top.lineWidth=2.0;[[safeAccent colorWithAlphaComponent:(.62+.24*hover)]setStroke];[top stroke];
    CGFloat cx=NSMidX(self.bounds);NSRect halo=NSMakeRect(cx-43,22,86,86);NSGradient *glow=[[NSGradient alloc]initWithStartingColor:[safeAccent colorWithAlphaComponent:(.24+.12*hover)] endingColor:NSColor.clearColor];[glow drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:halo] relativeCenterPosition:NSZeroPoint];
    NSImageSymbolConfiguration *palette=[NSImageSymbolConfiguration configurationWithPaletteColors:@[safeAccent]];NSImage *icon=[self.symbolImage imageWithSymbolConfiguration:palette]?:self.symbolImage;[icon drawInRect:NSMakeRect(cx-30,35,60,60) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
    NSMutableParagraphStyle *center=[NSMutableParagraphStyle new];center.alignment=NSTextAlignmentCenter;center.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.cardTitle drawInRect:NSMakeRect(18,118,self.bounds.size.width-36,30) withAttributes:@{NSFontAttributeName:ZZCuteFont(22),NSForegroundColorAttributeName:NSColor.whiteColor,NSParagraphStyleAttributeName:center}];
    [self.cardDetail drawInRect:NSMakeRect(18,158,self.bounds.size.width-36,25) withAttributes:@{NSFontAttributeName:ZZCuteFont(16),NSForegroundColorAttributeName:RC(.76,.80,.90,1),NSParagraphStyleAttributeName:center}];
    for(NSInteger side=0;side<2;side++){CGFloat x=side?NSMaxX(b)-22:NSMinX(b)+22;NSBezierPath *tick=[NSBezierPath bezierPath];[tick moveToPoint:NSMakePoint(x,24)];[tick lineToPoint:NSMakePoint(x+(side?-18:18),24)];tick.lineWidth=1;[[safeAccent colorWithAlphaComponent:.55]setStroke];[tick stroke];}
}
@end
