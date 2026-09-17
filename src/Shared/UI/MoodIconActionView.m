//
//  MoodIconActionView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "MoodIconActionView.h"
#import "UIThemeSupport.h"

@implementation MoodIconActionView
- (instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){_enabled=YES;}return self;}
- (void)drawRect:(NSRect)dirtyRect { NSRect target=NSInsetRect(self.bounds,5,5); [C(0.60,0.67,0.75,1) set]; [self.image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil]; }
- (void)mouseDown:(NSEvent *)event { if(!self.enabled)return; if(self.target&&self.action)[NSApp sendAction:self.action to:self.target from:self]; }
- (BOOL)acceptsFirstResponder { return YES; }
@end
