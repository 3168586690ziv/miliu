//
//  IconButton.m — 模块 09
//
#import "IconButton.h"

@interface IconButton ()
@property (nonatomic, strong) NSImageView *imageLayerView;
@end

@implementation IconButton

- (nullable instancetype)initWithSymbol:(NSString *)symbol
                     accessibilityLabel:(NSString *)label
                                  target:(nullable id)target
                                  action:(nullable SEL)action {
    // 无障碍标签必填：纯图标必须对 VoiceOver 可读
    if (label.length == 0) return nil;
    if (symbol.length == 0) return nil;

    self = [super initWithFrame:NSMakeRect(0, 0, 28, 28)];
    if (self) {
        _pointSize = 16;
        _weight = NSFontWeightSemibold;
        _symbolName = [symbol copy];
        self.target = target;
        self.action = action;

        _imageLayerView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageLayerView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageLayerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_imageLayerView];

        [self reloadIcon];

        // 强制无障碍角色与标签，且视觉标题恒为空
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        self.iconAccessibilityLabel = label;
    }
    return self;
}

- (void)setIconAccessibilityLabel:(NSString *)label {
    _iconAccessibilityLabel = [label copy];
    [self setAccessibilityLabel:label];
}

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    [self reloadIcon];
}

- (void)setIconImage:(NSImage *)iconImage {
    _iconImage = iconImage;
    [self reloadIcon];
}

- (void)setPointSize:(CGFloat)pointSize { _pointSize = pointSize; [self reloadIcon]; }
- (void)setWeight:(NSFontWeight)weight { _weight = weight; [self reloadIcon]; }

- (void)reloadIcon {
    NSImage *image = self.iconImage;
    if (!image && self.symbolName.length) {
        image = [NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:self.iconAccessibilityLabel];
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:self.pointSize
                                                                                          weight:self.weight
                                                                                           scale:NSImageSymbolScaleMedium];
        image = [image imageWithSymbolConfiguration:cfg] ?: image;
        image.template = YES;
    }
    self.imageLayerView.image = image;
}

// 纯图标按钮永不显示文字标题
- (NSString *)visibleTitle { return @""; }

- (BOOL)iconIsVisible {
    return self.imageLayerView.image != nil && !self.imageLayerView.hidden;
}

@end
