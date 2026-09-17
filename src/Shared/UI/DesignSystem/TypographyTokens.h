//
//  TypographyTokens.h — 模块 09｜共享 UI 设计令牌（字体）
//
//  字号/字重取自现有页面 systemFontOfSize / monospacedSystemFontOfSize 调用。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TypographyTokens : NSObject

// 语义字体（取自真实取值）
+ (NSFont *)caption;      // 11  regular
+ (NSFont *)footnote;     // 12  regular
+ (NSFont *)body;         // 13  regular
+ (NSFont *)bodyEmphasis; // 14  semibold
+ (NSFont *)title;        // 16  semibold
+ (NSFont *)largeTitle;   // 22  bold
+ (NSFont *)hero;         // 28  thin
+ (NSFont *)monoSmall;    // 12  mono regular
+ (NSFont *)mono;         // 14  mono semibold

// ── R7 统一视觉：补充档位与语义字体（值取自现有页面高频字号）──
+ (NSFont *)micro;        // 10  regular（极小辅助）
+ (NSFont *)subhead;      // 15  regular（次级标题/强调正文）
+ (NSFont *)number;       // 17  semibold（指标数值）
+ (NSFont *)sectionTitle; // 18  semibold（区块标题）
+ (NSFont *)metricValue;  // 19  bold（指标数值大号）
+ (NSFont *)panelTitle;   // 21  semibold（弹窗/面板标题）
+ (NSFont *)pageTitle;    // 26  bold（页面标题）
+ (NSFont *)metricValueLarge; // 30  bold（主指标超大数值）
+ (NSFont *)monoMedium;   // 15  mono semibold（等宽指标）
+ (NSFont *)monoLarge;    // 19  mono bold（等宽大数值）

// 原始字号常量（供测试与布局引用）
+ (CGFloat)sizeCaption;      // 11
+ (CGFloat)sizeFootnote;     // 12
+ (CGFloat)sizeBody;         // 13
+ (CGFloat)sizeBodyEmphasis; // 14
+ (CGFloat)sizeTitle;        // 16
+ (CGFloat)sizeLargeTitle;   // 22
+ (CGFloat)sizeHero;         // 28

// ── R7 补充字号常量 ──
+ (CGFloat)sizeMicro;        // 10
+ (CGFloat)sizeSubhead;      // 15
+ (CGFloat)sizeNumber;       // 17
+ (CGFloat)sizeSectionTitle; // 18
+ (CGFloat)sizeMetricValue;  // 19
+ (CGFloat)sizePanelTitle;   // 21
+ (CGFloat)sizePageTitle;    // 26
+ (CGFloat)sizeMetricValueLarge; // 30

@end

NS_ASSUME_NONNULL_END
