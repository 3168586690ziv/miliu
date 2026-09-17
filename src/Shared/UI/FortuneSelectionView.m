//
//  FortuneSelectionView.m — 迁移自 App/SevenZZToolbox.m，实现逐字符保留。
//
#import "FortuneSelectionView.h"
#import "UIThemeSupport.h"

@implementation FortuneSelectionView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.layer.masksToBounds = NO;
        _selectedIndex = 2;
        _highlightLayer = [CALayer layer];
        _highlightLayer.backgroundColor = NSColor.clearColor.CGColor;
        _highlightLayer.cornerRadius = 10;
        _highlightLayer.borderWidth = 2.5;
        _highlightLayer.borderColor = (gLavenderTheme ? RC(.96,.92,1.0,1.0)
                                         : (gLightTheme ? RC(1,1,1,1.0)
                                                        : RC(.92,.94,1.0,1.0))).CGColor;
        [self.layer addSublayer:_highlightLayer];
    }
    return self;
}

- (BOOL)isOpaque { return NO; }

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.highlightLayer.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.highlightLayer.bounds = CGRectMake(0, 0, 52.0, MAX(1.0, NSHeight(self.bounds) - 8.0));
    self.highlightLayer.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

- (NSArray<NSNumber *> *)animateFromIndex:(NSInteger)startIndex
                                  toIndex:(NSInteger)targetIndex
                                 duration:(NSTimeInterval)duration {
    NSInteger idx = MAX(0, MIN(4, startIndex));
    NSInteger target = MAX(0, MIN(4, targetIndex));
    NSInteger direction = 1;
    NSMutableArray<NSNumber *> *indices = [NSMutableArray arrayWithObject:@(idx)];

    // 高亮框在固定五符文上往返巡回；符文层本身完全不移动。
    for (NSInteger step = 0; step < 24; step++) {
        if ((idx == 4 && direction > 0) || (idx == 0 && direction < 0)) direction *= -1;
        idx += direction;
        [indices addObject:@(idx)];
    }
    while (idx != target) {
        idx += (target > idx) ? 1 : -1;
        [indices addObject:@(idx)];
    }

    CGFloat segW = MAX(1.0, NSWidth(self.bounds) / 5.0);
    NSMutableArray<NSNumber *> *xValues = [NSMutableArray arrayWithCapacity:indices.count];
    for (NSNumber *n in indices) {
        [xValues addObject:@((n.integerValue + 0.5) * segW)];
    }

    CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    move.values = xValues;
    move.duration = duration;
    move.calculationMode = kCAAnimationLinear;
    move.fillMode = kCAFillModeForwards;
    move.removedOnCompletion = NO;
    [self.highlightLayer addAnimation:move forKey:@"fortuneSelectionMove"];
    return indices;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGFloat w = NSWidth(b), h = NSHeight(b);
    // 横向基准线不覆盖文字，只辅助表达这是同一条五符文轨道。
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(0, h * 0.5)];
    [line lineToPoint:NSMakePoint(w, h * 0.5)];
    [RC(1,1,1,.18) setStroke];
    line.lineWidth = 1.0;
    [line stroke];
}

@end
