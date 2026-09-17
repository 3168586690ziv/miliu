//
//  HoverableControl.h — 模块 09｜可悬停控件基类
//
//  使用 NSTrackingInVisibleRect；窗口失焦、移除和鼠标离开时清除 hover。
//  hover 必须可逆，快速进出不粘住。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ControlVisualState) {
    ControlVisualNormal = 0,
    ControlVisualHovered,
    ControlVisualPressed,
    ControlVisualFocused,
    ControlVisualSelected,
    ControlVisualDisabled,
};

@interface HoverableControl : NSControl

@property (nonatomic, readonly) BOOL hovered;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, readonly) ControlVisualState visualState;

// 子类可覆写以响应外观变化（默认触发重绘）
- (void)hoverStateChanged;

// 供测试直接驱动 hover 生命周期（真实事件在运行时由 NSTrackingArea 触发）
- (void)beginHover;
- (void)endHover;

// 窗口失焦/移除时清除（内部调用，暴露供测试）
- (void)clearHoverForWindowChange;

@end

NS_ASSUME_NONNULL_END
