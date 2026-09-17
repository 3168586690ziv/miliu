//
//  TypographyTokens.m — 模块 09
//
#import "TypographyTokens.h"

@implementation TypographyTokens

+ (NSFont *)caption      { return [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]; }
+ (NSFont *)footnote     { return [NSFont systemFontOfSize:12 weight:NSFontWeightRegular]; }
+ (NSFont *)body         { return [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]; }
+ (NSFont *)bodyEmphasis { return [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]; }
+ (NSFont *)title        { return [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]; }
+ (NSFont *)largeTitle   { return [NSFont systemFontOfSize:22 weight:NSFontWeightBold]; }
+ (NSFont *)hero         { return [NSFont systemFontOfSize:28 weight:NSFontWeightThin]; }
+ (NSFont *)monoSmall    { return [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]; }
+ (NSFont *)mono         { return [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightSemibold]; }

// ── R7 补充档位与语义字体 ──
+ (NSFont *)micro        { return [NSFont systemFontOfSize:10 weight:NSFontWeightRegular]; }
+ (NSFont *)subhead      { return [NSFont systemFontOfSize:15 weight:NSFontWeightRegular]; }
+ (NSFont *)number       { return [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold]; }
+ (NSFont *)sectionTitle { return [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold]; }
+ (NSFont *)metricValue  { return [NSFont systemFontOfSize:19 weight:NSFontWeightBold]; }
+ (NSFont *)panelTitle   { return [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold]; }
+ (NSFont *)pageTitle    { return [NSFont systemFontOfSize:26 weight:NSFontWeightBold]; }
+ (NSFont *)metricValueLarge { return [NSFont systemFontOfSize:30 weight:NSFontWeightBold]; }
+ (NSFont *)monoMedium   { return [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightSemibold]; }
+ (NSFont *)monoLarge    { return [NSFont monospacedSystemFontOfSize:19 weight:NSFontWeightBold]; }

+ (CGFloat)sizeCaption      { return 11; }
+ (CGFloat)sizeFootnote     { return 12; }
+ (CGFloat)sizeBody         { return 13; }
+ (CGFloat)sizeBodyEmphasis { return 14; }
+ (CGFloat)sizeTitle        { return 16; }
+ (CGFloat)sizeLargeTitle   { return 22; }
+ (CGFloat)sizeHero         { return 28; }

// ── R7 补充字号常量 ──
+ (CGFloat)sizeMicro        { return 10; }
+ (CGFloat)sizeSubhead      { return 15; }
+ (CGFloat)sizeNumber       { return 17; }
+ (CGFloat)sizeSectionTitle { return 18; }
+ (CGFloat)sizeMetricValue  { return 19; }
+ (CGFloat)sizePanelTitle   { return 21; }
+ (CGFloat)sizePageTitle    { return 26; }
+ (CGFloat)sizeMetricValueLarge { return 30; }

@end
