//
//  ColorTokens.m — 模块 09
//
#import "ColorTokens.h"

static AppThemeMode gTokensTheme = AppThemeModeBlack;
static BOOL gTokensContrast = NO;

@implementation ColorTokens

+ (void)setLightTheme:(BOOL)light { gTokensTheme = light ? AppThemeModeLight : AppThemeModeBlack; }
+ (BOOL)isLightTheme { return gTokensTheme != AppThemeModeBlack; }
+ (void)setThemeMode:(AppThemeMode)mode { gTokensTheme = mode; }
+ (AppThemeMode)themeMode { return gTokensTheme; }
+ (void)setIncreaseContrast:(BOOL)on { gTokensContrast = on; }
+ (BOOL)increaseContrast { return gTokensContrast; }

// 复刻 SevenZZToolbox.m 的 C() 逻辑，保证与现有页面一致。
+ (NSColor *)colorR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b a:(CGFloat)a {
    if ([self isLightTheme]) {
        double luminance = r * 0.299 + g * 0.587 + b * 0.114;
        if (luminance < 0.42) {
            if (gTokensTheme == AppThemeModeLavender) {
                r = 0.972 - r * 0.08; g = 0.950 - g * 0.05; b = 1.0 - b * 0.018;
            } else {
                r = 0.96 - r * 0.12; g = 0.97 - g * 0.12; b = 0.985 - b * 0.12;
            }
        } else if (luminance > 0.62 && fabs(r - g) < 0.18 && fabs(g - b) < 0.18) {
            if (gTokensTheme == AppThemeModeLavender) { r = .188; g = .162; b = .270; }
            else { r = 0.16; g = 0.18; b = 0.22; }
        }
    }
    if (gTokensContrast) {
        // 高对比度：文字向两端推、透明度补满，不改变色相
        double luminance = r * 0.299 + g * 0.587 + b * 0.114;
        if (luminance > 0.5) { r = MIN(1.0, r + (1.0 - r) * 0.35); g = MIN(1.0, g + (1.0 - g) * 0.35); b = MIN(1.0, b + (1.0 - b) * 0.35); }
        else { r *= 0.7; g *= 0.7; b *= 0.7; }
        if (a < 1.0) a = MIN(1.0, a + (1.0 - a) * 0.5);
    }
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}

+ (NSColor *)accent        { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.665 green:.573 blue:.980 alpha:1] : [self colorR:0.47 g:0.18 b:1.00 a:1.0]; }
+ (NSColor *)background     { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.953 green:.933 blue:1 alpha:1] : [self colorR:0.012 g:0.013 b:0.016 a:1.0]; }
+ (NSColor *)surface        { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.985 green:.970 blue:1 alpha:.82] : [self colorR:0.055 g:0.052 b:0.10 a:0.98]; }
+ (NSColor *)textPrimary    { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.188 green:.162 blue:.270 alpha:1] : [self colorR:0.90 g:0.93 b:0.98 a:1.0]; }
+ (NSColor *)textSecondary  { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.455 green:.420 blue:.557 alpha:1] : [self colorR:0.78 g:0.83 b:0.90 a:1.0]; }
+ (NSColor *)textTertiary   { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.612 green:.565 blue:.700 alpha:1] : [self colorR:0.50 g:0.56 b:0.62 a:1.0]; }
+ (NSColor *)error          { return [self colorR:0.90 g:0.26 b:0.22 a:1.0]; }
+ (NSColor *)stale          { return [self colorR:0.95 g:0.72 b:0.28 a:1.0]; }

// ── R7 统一视觉语义色（主题感知，值取自现有页面高频取值）──
// 涨跌色遵循 A 股习惯：红涨绿跌。深/浅色取值与各页面原有真实值一致。
// 主题判断全部基于内部 gTokensTheme（由 App 在启动/切换主题时同步），
// 不引用任何 App 层符号，保证 Shared 层可独立编译。
+ (NSColor *)positive { return gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:.92 green:.28 blue:.36 alpha:1] : [self colorR:0.90 g:0.25 b:0.25 a:1.0]; }
+ (NSColor *)negative { return gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:.03 green:.61 blue:.45 alpha:1] : [self colorR:0.18 g:0.62 b:0.48 a:1.0]; }
// 通用分隔线：低对比中性，深色半透明白、浅色半透明灰；薰衣草主题带淡紫。
+ (NSColor *)divider  { return gTokensTheme == AppThemeModeLavender ? [self colorR:0.66 g:0.58 b:0.88 a:0.28] : (gTokensTheme != AppThemeModeBlack ? [self colorR:0.68 g:0.70 b:0.75 a:0.48] : [self colorR:0.24 g:0.28 b:0.36 a:0.55]); }
+ (NSColor *)border   { return gTokensTheme == AppThemeModeLavender ? [self colorR:0.66 g:0.58 b:0.88 a:0.42] : (gTokensTheme != AppThemeModeBlack ? [self colorR:0.68 g:0.70 b:0.75 a:0.48] : [self colorR:0.24 g:0.28 b:0.36 a:0.90]); }
+ (NSColor *)inputBackground { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.985 green:.970 blue:1 alpha:.82] : (gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:.96] : [self colorR:0.065 g:0.071 b:0.092 a:1.0]); }
+ (NSColor *)inputBorder { return [self border]; }
// 主按钮：统一品牌紫（与 accent 同一色系；浅色加深保证对比度）。
+ (NSColor *)buttonPrimaryBackground { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.665 green:.573 blue:.980 alpha:1] : (gTokensTheme != AppThemeModeBlack ? [self colorR:0.37 g:0.20 b:0.92 a:1.0] : [self colorR:0.65 g:0.52 b:1.00 a:1.0]); }
+ (NSColor *)buttonPrimaryText { return [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:1]; }
+ (NSColor *)buttonSecondaryBackground { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:.72] : (gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:.96] : [self colorR:0.065 g:0.071 b:0.092 a:1.0]); }
+ (NSColor *)buttonSecondaryBorder { return [self border]; }
// 紫色图标强调（指标图标/弹窗图标统一取色）。
+ (NSColor *)iconAccent { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.60 green:.48 blue:.93 alpha:.9] : [self colorR:0.42 g:0.25 b:0.92 a:1.0]; }

// ── R7.1 统一视觉：补充高频语义色（页面审计收敛）──
// pageBackground：设置/系统记录等整页背景（深色近黑、浅色近白、薰衣草奶白）。
+ (NSColor *)pageBackground { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.982 green:.972 blue:1 alpha:1] : (gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:.995 green:.997 blue:1 alpha:1] : [self colorR:0.006 g:0.007 b:0.011 a:1.0]); }
// cardBackground：内容卡片面（KPI 卡/面板卡，比 surface 略亮以区分页面背景）。
+ (NSColor *)cardBackground { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.995 green:.99 blue:1 alpha:.96] : (gTokensTheme != AppThemeModeBlack ? [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:.98] : [self colorR:0.022 g:0.024 b:0.033 a:1.0]); }
// selectionBackground：选中态淡紫底（导航项/筛选项选中，浅色加深保证可见）。
+ (NSColor *)selectionBackground { return gTokensTheme == AppThemeModeLavender ? [self colorR:0.55 g:0.38 b:1.0 a:0.14] : (gTokensTheme != AppThemeModeBlack ? [self colorR:0.55 g:0.38 b:1.0 a:0.14] : [self colorR:0.55 g:0.38 b:1.0 a:0.12]); }
// accentStrong：强调紫文字/图标（选中项、主链接；页面真实值 C(.56,.38,1,1) 各主题均不触发浅色变换）。
+ (NSColor *)accentStrong { return [self colorR:0.56 g:0.38 b:1.0 a:1.0]; }
// hoverBackground：可点项 hover 淡紫底。
+ (NSColor *)hoverBackground { return gTokensTheme != AppThemeModeBlack ? [self colorR:0.55 g:0.38 b:1.0 a:0.08] : [self colorR:0.55 g:0.38 b:1.0 a:0.10]; }
// iconTintBackground：图标浅紫底（主页指标图标光学容器背景；页面真实值 RC(.89,.84,1,.78)）。
+ (NSColor *)iconTintBackground { return gTokensTheme == AppThemeModeLavender ? [self colorR:0.92 g:0.88 b:1.0 a:0.85] : (gTokensTheme != AppThemeModeBlack ? [self colorR:0.91 g:0.90 b:0.97 a:0.80] : [self colorR:0.89 g:0.84 b:1.0 a:0.78]); }
// textOnDark：深色表面上使用的主文字（接近纯白）。
+ (NSColor *)textOnDark { return [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:1]; }
// textOnLight：浅色表面上使用的主文字（固定深色，不随主题变换；用于固定浅色面板/输入框）。
+ (NSColor *)textOnLight { return gTokensTheme == AppThemeModeLavender ? [NSColor colorWithCalibratedRed:.188 green:.162 blue:.270 alpha:1] : [NSColor colorWithCalibratedRed:.12 green:.14 blue:.18 alpha:1]; }
// textOnLightSecondary：浅色表面次文字（固定中灰；弹窗副标题/说明）。
+ (NSColor *)textOnLightSecondary { return [NSColor colorWithCalibratedRed:.38 green:.43 blue:.53 alpha:1]; }
// panelBackground：固定浅色弹窗/面板背景（全主题一致，表单弹窗用）。
+ (NSColor *)panelBackground { return [NSColor colorWithCalibratedRed:.955 green:.975 blue:.992 alpha:1]; }
// panelSecondaryBackground：固定浅色输入框/次按钮底（全主题一致）。
+ (NSColor *)panelSecondaryBackground { return [NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:1]; }
// panelBorder：固定浅色面板描边（全主题一致）。
+ (NSColor *)panelBorder { return [NSColor colorWithCalibratedRed:.67 green:.70 blue:.77 alpha:.65]; }

@end
