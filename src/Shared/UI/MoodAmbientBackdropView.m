//
//  MoodAmbientBackdropView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "MoodAmbientBackdropView.h"

@implementation MoodAmbientBackdropView
- (instancetype)initWithFrame:(NSRect)frame { if((self=[super initWithFrame:frame])){ self.wantsLayer=YES; self.layer=[CALayer layer]; } return self; }
- (NSView *)hitTest:(NSPoint)aPoint { return nil; }   // 点击穿透
@end
