//
//  LayoutMetrics.h — 模块 09｜共享 UI 设计令牌（间距/圆角/动画）
//
//  间距、圆角、动画时长取自现有页面约束常量与动画调用。
//  支持"减少动态效果"：开启后所有动画时长归零。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface LayoutMetrics : NSObject

// 减少动态效果（无障碍）
+ (void)setReduceMotion:(BOOL)on;
+ (BOOL)reduceMotion;

// 间距刻度（取自 constraint constant 高频值；R6 起新增 space*/语义 token，常规布局只允许有限值）
+ (CGFloat)spacingXS;   // 6
+ (CGFloat)spacingS;    // 8
+ (CGFloat)spacingM;    // 12
+ (CGFloat)spacingL;    // 16
+ (CGFloat)spacingXL;   // 22
+ (CGFloat)spacingXXL;  // 28
+ (CGFloat)spacingSection; // 36

// ── R6 设计系统刻度 ──
+ (CGFloat)space2;   // 2
+ (CGFloat)space4;   // 4
+ (CGFloat)space6;   // 6
+ (CGFloat)space8;   // 8
+ (CGFloat)space12;  // 12
+ (CGFloat)space16;  // 16
+ (CGFloat)space20;  // 20
+ (CGFloat)space24;  // 24
+ (CGFloat)space32;  // 32

// 页面与容器语义 token
+ (CGFloat)pageMargin;        // 24（紧凑 >=16）
+ (CGFloat)pageMarginCompact; // 16
+ (CGFloat)blockGap;          // 24（一级区块 20–24）
+ (CGFloat)cardGap;           // 16（卡片 12–16）
+ (CGFloat)cardPadding;       // 16（卡片内边距）
+ (CGFloat)cardPaddingDense;  // 12（密集卡片，同类一致）
+ (CGFloat)titleToBody;       // 8
+ (CGFloat)bodyToCaption;     // 4（正文/辅助 4–6）
+ (CGFloat)iconToText;        // 8
+ (CGFloat)textToDivider;     // 8

// 控件尺寸 token
+ (CGFloat)rowHeightSetting;  // 44（设置行 40–44）
+ (CGFloat)rowHeightNav;      // 38（导航行 36–40）
+ (CGFloat)buttonHeight;      // 30（按钮 28–32）
+ (CGFloat)iconContainer16;   // 16pt 图标光学容器
+ (CGFloat)iconContainer20;   // 20pt 图标光学容器
+ (CGFloat)badgeHeight20;     // badge 规格
+ (CGFloat)badgeHeight24;
+ (CGFloat)badgeHeight28;

// 圆角刻度（取自 cornerRadius 高频值）
+ (CGFloat)radiusSmall;  // 8
+ (CGFloat)radiusMedium; // 12
+ (CGFloat)radiusLarge;  // 18
+ (CGFloat)radiusPill;   // 25

// ── R7 统一视觉：补充圆角档位（收敛页面全部 cornerRadius）──
+ (CGFloat)radiusTiny;     // 6（极小元素/badge）
+ (CGFloat)radiusDefault;  // 10（最常见控件圆角）
+ (CGFloat)radiusCard;     // 14（信息卡片）
+ (CGFloat)radiusPanel;    // 16（面板/大卡）
+ (CGFloat)radiusHero;     // 20（hero 大卡/弹窗）
+ (CGFloat)radiusWindow;   // 22（悬浮窗/技术面板）

// ── R7 统一视觉：补充间距档位（页面真实高频值收敛）──
+ (CGFloat)space3;   // 3
+ (CGFloat)space5;   // 5
+ (CGFloat)space7;   // 7
+ (CGFloat)space9;   // 9
+ (CGFloat)space10;  // 10
+ (CGFloat)space14;  // 14
+ (CGFloat)space18;  // 18

// ── R7 统一视觉：控件尺寸/内边距补充 ──
+ (CGFloat)inputHeight;      // 26（输入框统一高度）
+ (CGFloat)controlHeightSmall; // 24（小型控件）
+ (CGFloat)segmentedHeight;  // 32（分段控件）
+ (CGFloat)dividerHeight;    // 1（分割线）
+ (CGFloat)iconGlyphContainer; // 36（指标图标光学容器）
+ (CGFloat)insetCompact;     // 10（紧凑内边距）
+ (CGFloat)insetStandard;    // 14（常规内边距）
+ (CGFloat)insetLoose;       // 18（宽松内边距）

// ── R7.1 统一视觉：控件尺寸补充（页面审计收敛，值=现有高频真实值）──
+ (CGFloat)actionButtonHeight;  // 34（主操作按钮统一高度）
+ (CGFloat)navButtonHeight;     // 34（导航/侧栏按钮）
+ (CGFloat)navButtonWidth;      // 134（设置页侧栏按钮宽度）
+ (CGFloat)boardButtonHeight;   // 30（板块切换按钮）
+ (CGFloat)filterButtonHeight;  // 24（筛选按钮）
+ (CGFloat)rowHeightCompact;    // 32（紧凑行）
+ (CGFloat)panelHeaderHeight;   // 30（面板标题行）
+ (CGFloat)radiusControl;       // 9（控件/按钮标准圆角，页面高频值收敛）
+ (CGFloat)shadowRadiusSoft;    // 5（柔和阴影）
+ (CGFloat)shadowRadiusMedium;  // 10（常规卡片阴影）
+ (CGFloat)borderWidthStandard; // 1（标准描边）

// 动画时长（取自现有 duration；reduceMotion 时返回 0）
+ (NSTimeInterval)durationFast;     // 0.16
+ (NSTimeInterval)durationStandard; // 0.26
+ (NSTimeInterval)durationSlow;     // 0.34

@end

NS_ASSUME_NONNULL_END
