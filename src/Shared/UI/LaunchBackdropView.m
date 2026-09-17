//
//  LaunchBackdropView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "LaunchBackdropView.h"
#import "UIThemeSupport.h"

@implementation LaunchBackdropView
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds=self.bounds; NSGradient *background=[[NSGradient alloc]initWithStartingColor:RC(.006,.007,.014,1) endingColor:RC(.035,.018,.075,1)]; [background drawInRect:bounds angle:62];
    for(NSInteger i=0;i<62;i++){CGFloat x=fmod((i*83.0)+37,bounds.size.width);CGFloat y=fmod((i*137.0)+23,bounds.size.height);CGFloat radius=(i%4==0)?1.8:1.0;NSColor *color=(i%3==0)?RC(.30,.68,1,.48):RC(.68,.40,1,.40);[color setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x,y,radius,radius)]fill];}
    NSPoint center=NSMakePoint(NSMidX(bounds),NSMidY(bounds)+54); for(NSInteger i=0;i<3;i++){CGFloat radius=170+i*72;NSBezierPath *arc=[NSBezierPath bezierPath];[arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:18+i*17 endAngle:128+i*20];arc.lineWidth=.8;[RC(.38,.46,1,.13-i*.025) setStroke];[arc stroke];}
    for(NSInteger i=0;i<9;i++){CGFloat y=45+i*73;NSBezierPath *beam=[NSBezierPath bezierPath];[beam moveToPoint:NSMakePoint(0,y)];[beam lineToPoint:NSMakePoint(bounds.size.width,y+110)];beam.lineWidth=.45;[RC(.30,.58,1,.055) setStroke];[beam stroke];}
}
@end
