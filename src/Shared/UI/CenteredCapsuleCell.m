//
//  CenteredCapsuleCell.m — 实现见 CenteredCapsuleCell.h
//
#import "CenteredCapsuleCell.h"
#import <CoreText/CoreText.h>

// ── 字形 ink 度量（相对 baseline，非 flipped 坐标：正值在 baseline 上方）──
//   outCenterY      : 字形视觉中心相对 baseline 的偏移（>0 表示在 baseline 上方）
//   outBottomDepth  : 字形最低点相对 baseline 的深度（>0 表示在 baseline 下方）
//   outTopHeight    : 字形最高点相对 baseline 的高度（>0 表示在 baseline 上方）
static void ZZCapsuleInkMetrics(NSFont *font, NSAttributedString *text,
                                CGFloat *outCenterY, CGFloat *outBottomDepth, CGFloat *outTopHeight) {
    CGFloat centerY = (font.ascender + font.descender) * 0.5;   // 排版盒中心（中文≈字形中心）
    CGFloat bottom  = -font.descender;
    CGFloat top     = font.ascender;
    if (text.length > 0) {
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
        if (line) {
            CGRect ink = CTLineGetImageBounds(line, NULL);
            if (ink.size.height > 0.5) {                        // 有实际字形时用 ink 精确值
                centerY = ink.origin.y + ink.size.height * 0.5;
                bottom  = -ink.origin.y;
                top     = ink.origin.y + ink.size.height;
            }
            CFRelease(line);
        }
    }
    if (outCenterY)     *outCenterY     = centerY;
    if (outBottomDepth) *outBottomDepth = bottom;
    if (outTopHeight)   *outTopHeight   = top;
}

// ── 垂直居中行框：让字形视觉中心落在容器中心 ──
// 返回的矩形是「单行行框」（origin = baseline - ascender，高度 = 行高），
// 系统按行框内 ascender 定位 baseline，因此字形 ink 中心正好贴容器中心。
static NSRect ZZCapsuleCenteredRect(NSRect bounds, NSFont *font, NSAttributedString *text,
                                    CGFloat verticalAdjustment, CGFloat backingScale) {
    CGFloat inkCenterY = 0, inkBottom = 0, inkTop = 0;
    ZZCapsuleInkMetrics(font, text, &inkCenterY, &inkBottom, &inkTop);
    // baseline 目标位置：容器中心 - 字形中心偏移；verticalAdjustment 正值=下移
    CGFloat baselineY = NSMidY(bounds) - inkCenterY - verticalAdjustment;
    // 字形不越界钳制（宁可牺牲 0.5pt 光学居中，也绝不让文字贴边/裁切）
    CGFloat minBaseline = NSMinY(bounds) + inkBottom;
    CGFloat maxBaseline = NSMaxY(bounds) - inkTop;
    if (minBaseline < maxBaseline) {
        baselineY = MAX(minBaseline, MIN(maxBaseline, baselineY));
    }
    CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading);
    NSRect rect = bounds;
    rect.origin.y = baselineY - font.ascender;
    rect.size.height = lineHeight;
    // 像素对齐：行框原点对齐物理像素（避免 1x/2x 下文字边缘模糊）
    if (backingScale > 0) {
        rect.origin.y = round(rect.origin.y * backingScale) / backingScale;
    }
    return rect;
}

@implementation CenteredCapsuleTextFieldCell

- (CGFloat)zzEffectiveBackingScale {
    if (self.zzBackingScaleOverride > 0) return self.zzBackingScaleOverride;
    NSView *view = (NSView *)self.controlView;
    NSWindow *window = [view respondsToSelector:@selector(window)] ? view.window : nil;
    if (window.backingScaleFactor > 0) return window.backingScaleFactor;
    NSScreen *screen = NSScreen.mainScreen;
    return screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2.0;
}

- (NSAttributedString *)zzCapsuleAttributedText {
    NSAttributedString *as = self.attributedStringValue;
    if (as.length > 0) return as;
    NSFont *font = self.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    NSString *title = self.stringValue ?: self.title ?: @"";
    if (title.length == 0) return nil;
    return [[NSAttributedString alloc] initWithString:title
                                           attributes:@{NSFontAttributeName: font}];
}

- (NSRect)zzCenteredRectForBounds:(NSRect)bounds {
    NSFont *font = self.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    return ZZCapsuleCenteredRect(bounds, font, [self zzCapsuleAttributedText],
                                 self.verticalAdjustment, [self zzEffectiveBackingScale]);
}

// 公开布局查询接口（供几何测试断言字形 ink 中心贴容器中心）。
// 生产绘制路径只经过 drawInteriorWithFrame:inView:（单入口），此处不参与绘制。
- (NSRect)centeredTextRectForBounds:(NSRect)bounds {
    return [self zzCenteredRectForBounds:bounds];
}

// R2 收缩：只覆盖 drawInteriorWithFrame:inView:（实际绘制入口），让 super 负责
// 文字排版与绘制；不再重写 drawingRectForBounds:/titleRectForBounds:，避免重复
// 坐标修正、绕过 AppKit 正常文字绘制。本 cell 仅用于非编辑、非选择、单行纯文字
// 状态胶囊（capsuleLabel: 工厂已设 editable=NO/selectable=NO）。
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView {
    [super drawInteriorWithFrame:[self zzCenteredRectForBounds:frame] inView:controlView];
}

@end

@implementation CenteredCapsuleButtonCell

- (CGFloat)zzEffectiveBackingScale {
    if (self.zzBackingScaleOverride > 0) return self.zzBackingScaleOverride;
    NSView *view = (NSView *)self.controlView;
    NSWindow *window = [view respondsToSelector:@selector(window)] ? view.window : nil;
    if (window.backingScaleFactor > 0) return window.backingScaleFactor;
    NSScreen *screen = NSScreen.mainScreen;
    return screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2.0;
}

- (NSAttributedString *)zzCapsuleAttributedText {
    if (self.attributedTitle.length > 0) return self.attributedTitle;
    NSFont *font = self.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    NSString *title = self.title ?: @"";
    if (title.length == 0) return nil;
    return [[NSAttributedString alloc] initWithString:title
                                           attributes:@{NSFontAttributeName: font}];
}

// 只重写 titleRectForBounds:。不要重写 drawTitle:withFrame:inView:——
// macOS 11 (Big Sur) 起只要重写 drawTitle（哪怕只转调 super）标题就会被压到底部。
- (NSRect)titleRectForBounds:(NSRect)bounds {
    NSRect rect = [super titleRectForBounds:bounds];   // 保留水平定位（含 image 偏移）
    NSFont *font = self.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    NSRect centered = ZZCapsuleCenteredRect(bounds, font, [self zzCapsuleAttributedText],
                                            self.verticalAdjustment, [self zzEffectiveBackingScale]);
    rect.origin.y = centered.origin.y;
    rect.size.height = centered.size.height;
    return rect;
}

@end
