//
//  ZZTopNavigationView.h — 主页 UI 重构 01：自包含原生顶部导航壳
//
//  职责边界：
//  - 只负责顶部导航的呈现：品牌字、文字入口、功能库菜单、active/hover 状态、
//    720px 宽度下的原生降级（二级入口并入菜单）。
//  - 输入全部为已解析值：导航项模型（含 block 回调）、外观（颜色/字体）、
//    功能库菜单 provider。本组件不 import AppDelegate/EnvCore，
//    不读取主题全局或 UserDefaults（依赖方向 App -> Shared/UI）。
//  - 布局全程由明确约束控制；hover/active 仅改颜色，不产生布局跳动。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark 稳定导航标识

FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierBrand;     // Seven（行为同 Home）
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierHome;      // 主页
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierDelta;     // 三角洲情报
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierFund;      // 基金与存钱
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierCleanup;   // 清理中心
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierLibrary;   // 功能库（菜单）
FOUNDATION_EXPORT NSString * const ZZTopNavIdentifierSettings;  // 设置

/// 全尺寸模式所需最小宽度；低于该值进入紧凑降级。
FOUNDATION_EXPORT const CGFloat ZZTopNavFullModeMinimumWidth;
/// 导航壳固定高度。
FOUNDATION_EXPORT const CGFloat ZZTopNavigationViewHeight;

@interface ZZTopNavItemModel : NSObject

- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                           handler:(nullable void (^)(void))handler;

@property (readonly, copy) NSString *identifier;
@property (readonly, copy) NSString *title;
@property (readonly, copy, nullable) void (^handler)(void);

@end

#pragma mark 已解析外观输入

@interface ZZTopNavAppearance : NSObject

- (instancetype)initWithTextColor:(NSColor *)textColor
                      activeColor:(NSColor *)activeColor
                       hoverColor:(NSColor *)hoverColor
                      shadowColor:(NSColor *)shadowColor
                         itemFont:(NSFont *)itemFont
                        brandFont:(NSFont *)brandFont;

@property (readonly, strong) NSColor *textColor;
@property (readonly, strong) NSColor *activeColor;
@property (readonly, strong) NSColor *hoverColor;
@property (readonly, strong) NSColor *shadowColor;
@property (readonly, strong) NSFont *itemFont;
@property (readonly, strong) NSFont *brandFont;

@end

#pragma mark 顶部导航视图

@interface ZZTopNavigationView : NSView

/// 可注入的功能库菜单呈现器（测试替身 / 宿主扩展用）。
/// nil 时使用原生 -[NSMenu popUpMenuPositioningItem:atLocation:inView:]。
/// 注入后不真正弹出，只回传本次构建的真实 NSMenu 与来源按钮。
@property (nonatomic, copy, nullable) void (^onPresentLibraryMenu)(NSMenu *menu, NSView *sourceButton);

/// items 顺序即批准稿顺序：主页、三角洲情报、基金与存钱、清理中心、功能库、设置。
/// secondaryIdentifiers 中的项在紧凑宽度下隐藏并并入功能库菜单；
/// libraryMenuProvider 在每次菜单打开时调用（App 层借此实时读取 ToolLibrary store）。
- (instancetype)initWithBrandTitle:(NSString *)brandTitle
                             items:(NSArray<ZZTopNavItemModel *> *)items
          secondaryIdentifiers:(NSArray<NSString *> *)secondaryIdentifiers
          libraryMenuProvider:(NSArray<ZZTopNavItemModel *> *(^)(void))libraryMenuProvider
                    appearance:(ZZTopNavAppearance *)appearance;

/// 当前高亮 destination；置 nil 清除高亮。
@property (nonatomic, copy, nullable) NSString *activeItemIdentifier;
@property (nonatomic, readonly, strong) ZZTopNavAppearance *navAppearance;
/// 当前是否处于紧凑降级。
@property (nonatomic, readonly, getter=isCompact) BOOL compact;
/// 当前实际渲染为可见按钮的标识（含 brand/library/settings）。
@property (nonatomic, readonly, copy) NSArray<NSString *> *visibleItemIdentifiers;
/// 此刻打开功能库菜单将出现的条目标识序列（工具 + 紧凑时的溢出入口）。
- (NSArray<NSString *> *)currentMenuItemIdentifiers;

/// 以新的已解析外观整体刷新（App 在主题切换时调用；无布局跳动）。
- (void)applyAppearance:(ZZTopNavAppearance *)appearance;

/// 统一触达入口：模拟/触发指定导航项一次回调。找到并触发返回 YES。
- (BOOL)sendActionForItemWithIdentifier:(NSString *)identifier;

/// 指定导航项当前是否处于 active 高亮（供宿主同步与聚焦测试）。
- (BOOL)isItemActiveWithIdentifier:(NSString *)identifier;

/// 功能库菜单的唯一打开入口：鼠标点击、Space/Enter 等价激活（performClick:）、
/// 辅助功能 press 全部汇入本方法；不依赖鼠标坐标。event 仅用于定位弹出点，
/// 传 nil 时在按钮下方居中弹出。构建失败或无可达项返回 NO。
- (BOOL)openLibraryMenuFromEvent:(nullable NSEvent *)event;

/// 纯函数：给定宽度与两组候补，返回功能库菜单应包含的标识序列（测试与内部共用同一实现）。
+ (NSArray<NSString *> *)menuIdentifiersForWidth:(CGFloat)width
                                  toolIdentifiers:(NSArray<NSString *> *)toolIdentifiers
                              overflowIdentifiers:(NSArray<NSString *> *)overflowIdentifiers;

@end

NS_ASSUME_NONNULL_END
