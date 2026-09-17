//
//  QuietButton.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "QuietButton.h"

@implementation QuietButton
- (BOOL)acceptsFirstResponder{return YES;}
- (void)resetCursorRects { [super resetCursorRects]; if(self.enabled)[self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)highlight:(BOOL)flag {
}
@end
