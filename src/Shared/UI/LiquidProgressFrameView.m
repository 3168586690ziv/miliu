//
//  LiquidProgressFrameView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "LiquidProgressFrameView.h"
#import "UIThemeSupport.h"

@implementation LiquidProgressFrameView
- (BOOL)isFlipped{return YES;}
- (NSView *)hitTest:(NSPoint)point { return nil; } // visual overlay; controls beneath stay fully interactive
- (instancetype)initWithFrame:(NSRect)frame { if((self=[super initWithFrame:frame])){_minValue=0;_maxValue=100;self.wantsLayer=YES;self.layer.cornerRadius=17;self.layer.borderWidth=3;self.layer.borderColor=C(.08,.085,.095,.92).CGColor;}return self; }
- (void)dealloc { [_flowTimer invalidate]; }
- (void)setDoubleValue:(double)value{_doubleValue=MAX(self.minValue,MIN(self.maxValue,value));self.needsDisplay=YES;}
- (void)setMinValue:(double)value{_minValue=value;self.needsDisplay=YES;}
- (void)setMaxValue:(double)value{_maxValue=MAX(value,self.minValue);self.needsDisplay=YES;}
- (void)setActive:(BOOL)active { if(_active==active)return;_active=active;[_flowTimer invalidate];_flowTimer=nil;self.layer.cornerRadius=17;self.layer.borderWidth=active?4:3;self.layer.borderColor=(active?RC(.30,.76,1,.82):C(.08,.085,.095,.92)).CGColor;if(active){__weak typeof(self) weakSelf=self;_flowTimer=[NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *timer){typeof(self) self=weakSelf;if(!self){[timer invalidate];return;}self.phase+=.045;self.needsDisplay=YES;}];}self.needsDisplay=YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect box=NSInsetRect(self.bounds,2.5,2.5);CGFloat radius=15;NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:box xRadius:radius yRadius:radius];
    [[C(.018,.020,.024,.88) colorWithAlphaComponent:.88] setFill];[shape fill];shape.lineWidth=4.5;[C(.25,.26,.29,.55) setStroke];[shape stroke];
    if(!self.active)return;
    double range=MAX(1,self.maxValue-self.minValue);CGFloat fraction=MIN(1,MAX(0,(self.doubleValue-self.minValue)/range));
    // A soft water fill travels beneath the controls while the thick tube remains readable.
    [NSGraphicsContext saveGraphicsState];[shape addClip];
    CGFloat waterWidth=MAX(24,(box.size.width-6)*fraction);NSRect water=NSMakeRect(box.origin.x+3,box.origin.y+3,waterWidth,box.size.height-6);
    NSGradient *waterGradient=[[NSGradient alloc]initWithColorsAndLocations:RC(.10,.62,.96,.13),0,RC(.22,.78,1,.30),.48,RC(.12,.54,.92,.14),1,nil];[waterGradient drawInRect:water angle:0];
    CGFloat waveY=NSMaxY(water)-7;NSBezierPath *wave=[NSBezierPath bezierPath];[wave moveToPoint:NSMakePoint(NSMinX(water),waveY)];for(CGFloat x=NSMinX(water);x<=NSMaxX(water)+8;x+=8){CGFloat y=waveY+sinf(x*.12+self.phase*5)*1.5;[wave lineToPoint:NSMakePoint(x,y)];}[wave lineToPoint:NSMakePoint(NSMaxX(water),NSMaxY(water))];[wave lineToPoint:NSMakePoint(NSMinX(water),NSMaxY(water))];[wave closePath];[[RC(.62,.90,1,.16) colorWithAlphaComponent:.18] setFill];[wave fill];[NSGraphicsContext restoreGraphicsState];
    // Moving highlights make the border feel like a filled glass tube rather than a flat line.
    CGFloat dashPhase=fmod(self.phase*38,20);shape.lineWidth=4.5;[shape setLineDash:(CGFloat[]){12,8} count:2 phase:dashPhase];[[RC(.30,.76,1,.72) colorWithAlphaComponent:.72] setStroke];[shape stroke];[shape setLineDash:NULL count:0 phase:0];
}
@end
