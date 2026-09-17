//
//  ColorTokens.h — 模块 09｜共享 UI 设计令牌（颜色）
//
//  从现有页面（SevenZZToolbox.m 的 C()/RC() 调用）提取的真实调色板，
//  不自行更换风格。深色为基准值，浅色经与 App 相同的 C() 变换得到，
//  确保令牌产出的颜色与现有页面逐像素一致。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AppThemeMode) {
    AppThemeModeBlack = 0,
    AppThemeModeLight = 1,
    AppThemeModeLavender = 2,
};

@interface ColorTokens : NSObject

// 主题开关（与 App 全局 gLightTheme 语义一致）
+ (void)setLightTheme:(BOOL)light;
+ (BOOL)isLightTheme;
+ (void)setThemeMode:(AppThemeMode)mode;
+ (AppThemeMode)themeMode;

// 提高对比度（无障碍）
+ (void)setIncreaseContrast:(BOOL)on;
+ (BOOL)increaseContrast;

// 与现有 App 完全一致的取色入口（含浅色变换与高对比度加强）
+ (NSColor *)colorR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b a:(CGFloat)a;

// 语义令牌（取自现有页面真实取值）
+ (NSColor *)accent;         // 品牌紫 (0.47,0.18,1.0)
+ (NSColor *)background;     // 近黑背景 (0.012,0.013,0.016)
+ (NSColor *)surface;        // 卡片面 (0.055,0.052,0.10)
+ (NSColor *)textPrimary;    // 主文字 (0.90,0.93,0.98)
+ (NSColor *)textSecondary;  // 次文字 (0.78,0.83,0.90)
+ (NSColor *)textTertiary;   // 弱文字 (0.50,0.56,0.62)
+ (NSColor *)error;          // 错误强调（系统红）
+ (NSColor *)stale;          // 旧缓存提示（暖黄）

// ── R7 统一视觉语义色（主题感知；值取自现有页面高频取值）──
+ (NSColor *)positive;         // 正收益/上涨（A 股习惯：红）
+ (NSColor *)negative;         // 负收益/下跌（A 股习惯：绿）
+ (NSColor *)divider;          // 通用分隔线（低对比中性）
+ (NSColor *)border;           // 控件描边（按钮/输入框）
+ (NSColor *)inputBackground;  // 输入框背景
+ (NSColor *)inputBorder;      // 输入框描边
+ (NSColor *)buttonPrimaryBackground;    // 主按钮背景（品牌紫，主题感知）
+ (NSColor *)buttonPrimaryText;          // 主按钮文字
+ (NSColor *)buttonSecondaryBackground;  // 次按钮背景
+ (NSColor *)buttonSecondaryBorder;      // 次按钮描边
+ (NSColor *)iconAccent;       // 紫色图标强调

// ── R7.1 统一视觉：补充高频语义色（页面审计收敛）──
+ (NSColor *)pageBackground;   // 整页背景（设置/系统记录等）
+ (NSColor *)cardBackground;   // 内容卡片面（KPI 卡/面板卡）
+ (NSColor *)selectionBackground; // 选中态淡紫底
+ (NSColor *)accentStrong;     // 强调紫文字/图标（选中项、主链接）
+ (NSColor *)hoverBackground;  // hover 淡紫底
+ (NSColor *)iconTintBackground; // 图标浅紫底（指标图标光学容器）
+ (NSColor *)textOnDark;       // 深色表面主文字（近纯白）
+ (NSColor *)textOnLight;      // 浅色表面主文字（固定深色）
+ (NSColor *)textOnLightSecondary; // 浅色表面次文字（固定中灰）
+ (NSColor *)panelBackground;  // 固定浅色弹窗/面板背景（全主题一致）
+ (NSColor *)panelSecondaryBackground; // 固定浅色输入框/次按钮底
+ (NSColor *)panelBorder;      // 固定浅色面板描边

@end

NS_ASSUME_NONNULL_END
