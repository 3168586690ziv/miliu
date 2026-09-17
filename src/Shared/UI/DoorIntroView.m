//
//  DoorIntroView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "DoorIntroView.h"
#import "UIThemeSupport.h"

@implementation DoorIntroView
- (BOOL)isFlipped { return YES; }
- (void)setProgress:(CGFloat)progress { _progress=MAX(0,MIN(1,progress)); self.needsDisplay=YES; }
- (void)mouseDown:(NSEvent *)event { NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; NSPoint c=NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds)); if(self.progress==0 && hypot(p.x-c.x,p.y-c.y)<72 && self.openTarget && self.openAction) [NSApp sendAction:self.openAction to:self.openTarget from:self]; }
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height, mid=w/2.0;
    CGFloat impact=MIN(1,MAX(0,(self.progress-.06)/.16));
    CGFloat flowStage=MIN(1,MAX(0,(self.progress-.10)/.38));
    CGFloat doorStage=MIN(1,MAX(0,(self.progress-.58)/.42));
    CGFloat eased=1-pow(1-doorStage,2.5), shift=mid*eased;
    NSRect left=NSMakeRect(-shift,0,mid,h), right=NSMakeRect(mid+shift,0,mid,h);
    NSGradient *leftFill=[[NSGradient alloc]initWithStartingColor:RC(.018,.012,.035,1) endingColor:RC(.050,.020,.090,1)];
    NSGradient *rightFill=[[NSGradient alloc]initWithStartingColor:RC(.050,.020,.090,1) endingColor:RC(.018,.012,.035,1)];
    [leftFill drawInRect:left angle:0]; [rightFill drawInRect:right angle:180];
    {
        CGFloat reach=(mid-38)*flowStage, flowAlpha=MIN(.76,flowStage*1.65)*(1-doorStage*.86);
        for(NSInteger i=0;i<7;i++){CGFloat offset=(i-3)*48;CGFloat bend=(i%2?1:-1)*(22+i*3);for(NSInteger side=0;side<2;side++){[NSGraphicsContext saveGraphicsState];[[NSBezierPath bezierPathWithRect:side?right:left] addClip];NSBezierPath *flow=[NSBezierPath bezierPath];CGFloat startX=mid+(side?1:-1)*26;CGFloat endX=mid+(side?1:-1)*reach;[flow moveToPoint:NSMakePoint(startX,h/2+offset*.18)];[flow curveToPoint:NSMakePoint(endX,h/2+offset) controlPoint1:NSMakePoint(mid+(side?1:-1)*(reach*.28),h/2+offset+bend) controlPoint2:NSMakePoint(mid+(side?1:-1)*(reach*.72),h/2+offset-bend)];flow.lineWidth=i==3?1.8:0.75;[[RC(side ? .32 : .63, side ? .58 : .30, 1,flowAlpha*(i==3?1:.55)) colorWithAlphaComponent:flowAlpha*(i==3?1:.55)] setStroke];[flow stroke];[NSGraphicsContext restoreGraphicsState];}}
    }
    CGFloat lineAlpha=MAX(0,1-doorStage*1.35);
    [[RC(.60,.34,1,lineAlpha) colorWithAlphaComponent:lineAlpha] setStroke];
    NSBezierPath *split=[NSBezierPath bezierPath];[split moveToPoint:NSMakePoint(mid,0)];[split lineToPoint:NSMakePoint(mid,h)];split.lineWidth=1.2;[split stroke];
    CGFloat ringAlpha=MAX(0,1-doorStage*1.18), radius=35;
    NSPoint c=NSMakePoint(mid,h/2.0);
    CGFloat gearShift=25*MIN(1,impact*1.9)*(1-doorStage);
    for(NSInteger side=0;side<2;side++){CGFloat sign=side?1:-1;NSPoint gc=NSMakePoint(c.x+sign*gearShift,c.y);NSBezierPath *half=[NSBezierPath bezierPath];[half moveToPoint:NSMakePoint(gc.x,gc.y-radius)];[half appendBezierPathWithArcWithCenter:gc radius:radius startAngle:side?270:90 endAngle:side?90:270 clockwise:side?YES:NO];for(NSInteger tooth=0;tooth<=10;tooth++){CGFloat y=gc.y+radius-tooth*(radius*2/10.0);CGFloat x=gc.x+sign*((tooth%2)?5:-2);[half lineToPoint:NSMakePoint(x,y)];}[half closePath];[[RC(.08,.035,.15,.94) colorWithAlphaComponent:ringAlpha] setFill];[half fill];half.lineWidth=2.1;[[RC(.66,.38,1,ringAlpha) colorWithAlphaComponent:ringAlpha] setStroke];[half stroke];}
    if(self.progress==0){NSBezierPath *core=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-13,c.y-13,26,26)];[[RC(.18,.09,.34,.96) colorWithAlphaComponent:.96] setFill];[core fill];core.lineWidth=1.4;[[RC(.82,.68,1,.95) colorWithAlphaComponent:.95] setStroke];[core stroke];NSBezierPath *key=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-3,c.y-5,6,6)];[[NSColor.whiteColor colorWithAlphaComponent:.9] setFill];[key fill];NSBezierPath *stem=[NSBezierPath bezierPath];[stem moveToPoint:NSMakePoint(c.x,c.y+1)];[stem lineToPoint:NSMakePoint(c.x,c.y+7)];stem.lineWidth=2;[stem stroke];}
    else if(impact<.55){NSBezierPath *flash=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-4,c.y-4,8,8)];[[RC(.90,.78,1,(.55-impact)*1.4) colorWithAlphaComponent:(.55-impact)*1.4] setFill];[flash fill];}
}
@end
