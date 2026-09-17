//
//  InvisibleScroller.h — R49:透明滚动条(自 R40 起的统一实现,共享给各页面)
//  滚动能力完全保留,仅让竖直滚动指示器彻底不可见(覆盖绘制入口 + 强制 alpha=0)。
//
#import <Cocoa/Cocoa.h>

/// 统一安装入口:保留竖直滚动(滚轮/触控板/键盘),仅让指示器彻底不可见。
void ZZInstallInvisibleVerticalScroller(NSScrollView *sv);
/// 复核:任何时机(主题切换、重新布局、滚动结束)调用,保证仍为透明 scroller。
void ZZReassertInvisibleScrollers(void);
/// 查询:verticalScroller 是否为透明 ZZInvisibleScroller 且 alpha≈0(测试/诊断用)。
BOOL ZZInvisibleScrollerActive(NSScrollView *sv);
