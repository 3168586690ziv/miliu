//
//  FortuneSelectionView.h — 迁移自 App/SevenZZToolbox.m
//
//  今日抽签轮盘（自包含 NSView，视觉五等分；概率由引擎独立决定）。
//  高亮框在固定五符文上往返巡回；符文层本身完全不移动。
//
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface FortuneSelectionView : NSView
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, strong) CALayer *highlightLayer;
- (NSArray<NSNumber *> *)animateFromIndex:(NSInteger)startIndex
                                  toIndex:(NSInteger)targetIndex
                                 duration:(NSTimeInterval)duration;
@end
