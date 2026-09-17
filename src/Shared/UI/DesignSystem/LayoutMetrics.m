//
//  LayoutMetrics.m — 模块 09
//
#import "LayoutMetrics.h"

static BOOL gReduceMotion = NO;

@implementation LayoutMetrics

+ (void)setReduceMotion:(BOOL)on { gReduceMotion = on; }
+ (BOOL)reduceMotion { return gReduceMotion; }

+ (CGFloat)spacingXS      { return 6; }
+ (CGFloat)spacingS       { return 8; }
+ (CGFloat)spacingM       { return 12; }
+ (CGFloat)spacingL       { return 16; }
+ (CGFloat)spacingXL      { return 22; }
+ (CGFloat)spacingXXL     { return 28; }
+ (CGFloat)spacingSection { return 36; }

// ── R6 设计系统刻度（全局 UI 整改）：常规布局只允许以下有限值 ──
+ (CGFloat)space2  { return 2; }
+ (CGFloat)space4  { return 4; }
+ (CGFloat)space6  { return 6; }
+ (CGFloat)space8  { return 8; }
+ (CGFloat)space12 { return 12; }
+ (CGFloat)space16 { return 16; }
+ (CGFloat)space20 { return 20; }
+ (CGFloat)space24 { return 24; }
+ (CGFloat)space32 { return 32; }

// 页面与容器语义 token
+ (CGFloat)pageMargin          { return 24; }   // 页面内容区外边距（常规）
+ (CGFloat)pageMarginCompact   { return 16; }   // 紧凑状态最低外边距
+ (CGFloat)blockGap            { return 24; }   // 一级区块间距 20–24
+ (CGFloat)cardGap             { return 16; }   // 卡片间距 12–16
+ (CGFloat)cardPadding         { return 16; }   // 卡片内边距（常规）
+ (CGFloat)cardPaddingDense    { return 12; }   // 信息密集卡片内边距（同类一致）
+ (CGFloat)titleToBody         { return 8; }    // 标题/正文
+ (CGFloat)bodyToCaption       { return 4; }    // 正文/辅助说明 4–6
+ (CGFloat)iconToText          { return 8; }    // 图标/文字（紧凑 badge 4–6）
+ (CGFloat)textToDivider       { return 8; }    // 文字/图标到分割线

// 控件尺寸 token
+ (CGFloat)rowHeightSetting     { return 44; }  // 普通设置行 40–44
+ (CGFloat)rowHeightNav         { return 38; }  // 导航行 36–40
+ (CGFloat)buttonHeight         { return 30; }  // 普通按钮 28–32
+ (CGFloat)iconContainer16      { return 16; }  // 统一 16pt 图标光学容器
+ (CGFloat)iconContainer20      { return 20; }  // 统一 20pt 图标光学容器
+ (CGFloat)badgeHeight20        { return 20; }  // badge/pill 有限规格
+ (CGFloat)badgeHeight24        { return 24; }
+ (CGFloat)badgeHeight28        { return 28; }

+ (CGFloat)radiusSmall  { return 8; }
+ (CGFloat)radiusMedium { return 12; }
+ (CGFloat)radiusLarge  { return 18; }
+ (CGFloat)radiusPill   { return 25; }

// ── R7 补充圆角档位 ──
+ (CGFloat)radiusTiny    { return 6; }
+ (CGFloat)radiusDefault { return 10; }
+ (CGFloat)radiusCard    { return 14; }
+ (CGFloat)radiusPanel   { return 16; }
+ (CGFloat)radiusHero    { return 20; }
+ (CGFloat)radiusWindow  { return 22; }

// ── R7 补充间距档位 ──
+ (CGFloat)space3  { return 3; }
+ (CGFloat)space5  { return 5; }
+ (CGFloat)space7  { return 7; }
+ (CGFloat)space9  { return 9; }
+ (CGFloat)space10 { return 10; }
+ (CGFloat)space14 { return 14; }
+ (CGFloat)space18 { return 18; }

// ── R7 控件尺寸/内边距补充 ──
+ (CGFloat)inputHeight      { return 26; }
+ (CGFloat)controlHeightSmall { return 24; }
+ (CGFloat)segmentedHeight  { return 32; }
+ (CGFloat)dividerHeight    { return 1; }
+ (CGFloat)iconGlyphContainer { return 36; }
+ (CGFloat)insetCompact     { return 10; }
+ (CGFloat)insetStandard    { return 14; }
+ (CGFloat)insetLoose       { return 18; }

// ── R7.1 控件尺寸补充（值=现有高频真实值）──
+ (CGFloat)actionButtonHeight { return 34; }
+ (CGFloat)navButtonHeight    { return 34; }
+ (CGFloat)navButtonWidth     { return 134; }
+ (CGFloat)boardButtonHeight  { return 30; }
+ (CGFloat)filterButtonHeight { return 24; }
+ (CGFloat)rowHeightCompact   { return 32; }
+ (CGFloat)panelHeaderHeight  { return 30; }
+ (CGFloat)radiusControl      { return 9; }
+ (CGFloat)shadowRadiusSoft   { return 5; }
+ (CGFloat)shadowRadiusMedium { return 10; }
+ (CGFloat)borderWidthStandard { return 1; }

+ (NSTimeInterval)durationFast     { return gReduceMotion ? 0.0 : 0.16; }
+ (NSTimeInterval)durationStandard { return gReduceMotion ? 0.0 : 0.26; }
+ (NSTimeInterval)durationSlow     { return gReduceMotion ? 0.0 : 0.34; }

@end
