//
//  UIThemeSupport.h — 迁移自 App/SevenZZToolbox.m 的全局主题支撑
//
//  主文件历史沿用的静态辅助符号（gLightTheme/gLavenderTheme 主题开关、
//  RC/C 取色、ZZCuteFont 字体、Symbol/SymbolSized 符号图、ZZIsTestMode 测试模式、
//  ZZTestWindowLevel/ZZOrderTestWindowBehindFrontApp 测试窗口守卫）在多个 UI
//  类与 App 层之间共享，迁移为全局符号以保持单一实现与行为一致。
//  本文件仅依赖系统框架，不依赖 App/Features（保持 Shared 单向依赖约束）。
//
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

// 主题开关（与历史语义一致：gLightTheme=浅色，gLavenderTheme=奶紫浅色）
extern BOOL gLightTheme;
extern BOOL gLavenderTheme;

// 取色：RC 直取校准色；C 带浅色主题变换（与 App 全局行为逐字符一致）
NSColor *RC(double r, double g, double b, double a);
NSColor *C(double r, double g, double b, double a);

// 全局 UI 字体（系统字体，中文自动落到苹方）
NSFont *ZZCuteFont(CGFloat size);

// SF Symbols 模板图（24pt semibold large；按名称缓存）
NSImage *Symbol(NSString *name);
NSImage *SymbolSized(NSString *name, CGFloat pointSize, NSFontWeight weight);

// R6 后台无抢焦点测试模式判定（MARVIS_TEST_MODE 或显式环境变量）
BOOL ZZIsTestMode(void);

// 测试模式窗口排到当前前台 App 之后（FocusLoopWindow / NSWindow 守卫共用）
NSWindowLevel ZZTestWindowLevel(void);
void ZZOrderTestWindowBehindFrontApp(NSWindow *window);
